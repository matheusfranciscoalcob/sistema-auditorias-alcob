alter table public.auditorias
  add column if not exists supervisor_name text,
  add column if not exists audited_role text not null default 'supervisor';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'auditorias_audited_role_check'
      and conrelid = 'public.auditorias'::regclass
  ) then
    alter table public.auditorias
      add constraint auditorias_audited_role_check
      check (audited_role in ('supervisor', 'subordinado'));
  end if;
end $$;

update public.auditorias
set supervisor_name = team
where audited_role = 'supervisor'
  and nullif(btrim(supervisor_name), '') is null;

create table if not exists public.subordinacoes (
  id bigint generated always as identity primary key,
  setor text not null,
  supervisor text not null,
  subordinado text not null,
  cargo text not null default 'Operador',
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subordinacoes_setor_not_blank check (btrim(setor) <> ''),
  constraint subordinacoes_supervisor_not_blank check (btrim(supervisor) <> ''),
  constraint subordinacoes_subordinado_not_blank check (btrim(subordinado) <> ''),
  constraint subordinacoes_cargo_not_blank check (btrim(cargo) <> '')
);

alter table public.subordinacoes enable row level security;
revoke all on table public.subordinacoes from anon, authenticated;

create unique index if not exists subordinacoes_setor_subordinado_ativo_idx
  on public.subordinacoes (lower(setor), lower(subordinado))
  where ativo;

create index if not exists subordinacoes_setor_supervisor_ativo_idx
  on public.subordinacoes (setor, supervisor)
  where ativo;

create index if not exists auditorias_supervisor_name_idx
  on public.auditorias (supervisor_name)
  where supervisor_name is not null;

create or replace function public.get_subordinacoes_publicas()
returns table (
  id bigint,
  setor text,
  supervisor text,
  subordinado text,
  cargo text
)
language sql
security definer
set search_path = ''
as $$
  select s.id, s.setor, s.supervisor, s.subordinado, s.cargo
  from public.subordinacoes s
  where s.ativo
  order by s.setor, s.supervisor, s.subordinado;
$$;

revoke execute on function public.get_subordinacoes_publicas() from public;
grant execute on function public.get_subordinacoes_publicas() to anon, authenticated, service_role;

create or replace function public.save_subordinacao(
  p_password text,
  p_id bigint,
  p_setor text,
  p_supervisor text,
  p_subordinado text,
  p_cargo text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_setor text := btrim(coalesce(p_setor, ''));
  v_supervisor text := btrim(coalesce(p_supervisor, ''));
  v_subordinado text := btrim(coalesce(p_subordinado, ''));
  v_cargo text := btrim(coalesce(p_cargo, ''));
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;
  if v_setor = '' or v_supervisor = '' or v_subordinado = '' or v_cargo = '' then
    raise exception 'Preencha setor, supervisor, subordinado e cargo';
  end if;
  if lower(v_supervisor) = lower(v_subordinado) then
    raise exception 'Supervisor e subordinado devem ser pessoas diferentes';
  end if;

  update public.subordinacoes
  set ativo = false, updated_at = now()
  where ativo
    and lower(setor) = lower(v_setor)
    and lower(subordinado) = lower(v_subordinado)
    and (p_id is null or id <> p_id);

  if p_id is null then
    insert into public.subordinacoes (setor, supervisor, subordinado, cargo)
    values (v_setor, v_supervisor, v_subordinado, v_cargo)
    returning id into v_id;
  else
    update public.subordinacoes
    set setor = v_setor,
        supervisor = v_supervisor,
        subordinado = v_subordinado,
        cargo = v_cargo,
        ativo = true,
        updated_at = now()
    where id = p_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Vínculo de subordinação não encontrado';
    end if;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_subordinacao(text, bigint, text, text, text, text) from public;
grant execute on function public.save_subordinacao(text, bigint, text, text, text, text) to anon, authenticated, service_role;

create or replace function public.delete_subordinacao(
  p_password text,
  p_id bigint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;

  update public.subordinacoes
  set ativo = false, updated_at = now()
  where id = p_id and ativo;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

revoke execute on function public.delete_subordinacao(text, bigint) from public;
grant execute on function public.delete_subordinacao(text, bigint) to anon, authenticated, service_role;

create or replace function public.save_auditoria_contextual(
  p_password text,
  p_audit_id bigint,
  p_type text,
  p_team text,
  p_audit_date date,
  p_cargo text,
  p_score numeric,
  p_total_ok integer,
  p_total_no integer,
  p_report jsonb,
  p_supervisor_name text,
  p_audited_role text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := coalesce(nullif(btrim(p_audited_role), ''), 'supervisor');
  v_supervisor text := nullif(btrim(p_supervisor_name), '');
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;
  if v_role not in ('supervisor', 'subordinado') then
    raise exception 'Tipo de auditado inválido';
  end if;
  if v_role = 'subordinado' and v_supervisor is null then
    raise exception 'Informe o supervisor responsável pelo subordinado';
  end if;
  if v_role = 'supervisor' then
    v_supervisor := nullif(btrim(p_team), '');
  end if;

  insert into public.auditorias (
    audit_id, type, team, audit_date, cargo, score, total_ok, total_no, report,
    supervisor_name, audited_role
  ) values (
    p_audit_id, p_type, p_team, p_audit_date, p_cargo, p_score, p_total_ok, p_total_no,
    coalesce(p_report, '{}'::jsonb), v_supervisor, v_role
  )
  on conflict (audit_id) do update set
    type = excluded.type,
    team = excluded.team,
    audit_date = excluded.audit_date,
    cargo = excluded.cargo,
    score = excluded.score,
    total_ok = excluded.total_ok,
    total_no = excluded.total_no,
    report = excluded.report,
    supervisor_name = excluded.supervisor_name,
    audited_role = excluded.audited_role;

  return true;
end;
$$;

revoke execute on function public.save_auditoria_contextual(text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text) from public;
grant execute on function public.save_auditoria_contextual(text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text) to anon, authenticated, service_role;

create or replace function public.salvar_auditoria_text(p_payload text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  if p_payload is null or btrim(p_payload) = '' then
    raise exception 'Dados da auditoria não informados';
  end if;
  v_payload := p_payload::jsonb;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'Formato da auditoria inválido';
  end if;

  return public.save_auditoria_contextual(
    v_payload->>'p_password',
    (v_payload->>'p_audit_id')::bigint,
    v_payload->>'p_type',
    v_payload->>'p_team',
    (v_payload->>'p_audit_date')::date,
    v_payload->>'p_cargo',
    (v_payload->>'p_score')::numeric,
    (v_payload->>'p_total_ok')::integer,
    (v_payload->>'p_total_no')::integer,
    coalesce(v_payload->'p_report', '{}'::jsonb),
    v_payload->>'p_supervisor_name',
    v_payload->>'p_audited_role'
  );
end;
$$;

create or replace function public.get_auditorias_completas_v2(p_password text)
returns table (
  audit_id bigint,
  created_at timestamptz,
  type text,
  team text,
  audit_date date,
  cargo text,
  score numeric,
  total_ok integer,
  total_no integer,
  report jsonb,
  supervisor_name text,
  audited_role text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;

  return query
  select a.audit_id, a.created_at, a.type, a.team, a.audit_date, a.cargo,
         a.score, a.total_ok, a.total_no, a.report, a.supervisor_name, a.audited_role
  from public.auditorias a
  order by a.created_at asc;
end;
$$;

revoke execute on function public.get_auditorias_completas_v2(text) from public;
grant execute on function public.get_auditorias_completas_v2(text) to anon, authenticated, service_role;

create or replace view public.auditoria_resultados as
select audit_id,
       created_at,
       type,
       team,
       audit_date,
       cargo,
       score,
       total_ok,
       total_no,
       supervisor_name,
       audited_role
from public.auditorias;

revoke all on table public.auditoria_resultados from anon, authenticated;
grant select on table public.auditoria_resultados to anon, authenticated;
