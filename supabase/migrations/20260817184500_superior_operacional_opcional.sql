-- A tabela de subordinações permanece como cadastro operacional único, mas o
-- superior passa a ser opcional e pode ser qualquer liderança ativa.
alter table public.subordinacoes
  drop constraint if exists subordinacoes_supervisor_not_blank;

alter table public.subordinacoes
  alter column supervisor drop not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'subordinacoes_superior_null_ou_preenchido_check'
      and conrelid = 'public.subordinacoes'::regclass
  ) then
    alter table public.subordinacoes
      add constraint subordinacoes_superior_null_ou_preenchido_check
      check (supervisor is null or btrim(supervisor) <> '');
  end if;
end $$;

comment on column public.subordinacoes.supervisor is
  'Nome da liderança superior opcional: Supervisor, Gestor, Gerente ou Diretor.';

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
  v_supervisor text := nullif(btrim(coalesce(p_supervisor, '')), '');
  v_supervisor_canonico text;
  v_subordinado text := btrim(coalesce(p_subordinado, ''));
  v_cargo text := btrim(coalesce(p_cargo, ''));
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;

  if v_setor = '' or v_subordinado = '' or v_cargo = '' then
    raise exception 'Preencha setor, colaborador e cargo; o superior é opcional';
  end if;

  if v_supervisor is not null then
    select lider.nome
    into v_supervisor_canonico
    from public.liderancas lider
    where lider.ativo
      and lider.cargo in ('Supervisor', 'Gestor', 'Gerente', 'Diretor')
      and lower(btrim(lider.nome)) = lower(v_supervisor)
    order by case lider.cargo
      when 'Supervisor' then 1
      when 'Gestor' then 2
      when 'Gerente' then 3
      when 'Diretor' then 4
      else 99
    end,
    lider.id
    limit 1;

    if v_supervisor_canonico is null then
      raise exception 'Selecione uma liderança ativa já cadastrada ou deixe o superior vazio';
    end if;

    v_supervisor := v_supervisor_canonico;

    if lower(v_supervisor) = lower(v_subordinado) then
      raise exception 'Superior e colaborador devem ser pessoas diferentes';
    end if;
  end if;

  update public.subordinacoes
  set ativo = false,
      updated_at = now()
  where ativo
    and lower(btrim(setor)) = lower(v_setor)
    and lower(btrim(subordinado)) = lower(v_subordinado)
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
      raise exception 'Cadastro operacional não encontrado';
    end if;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_subordinacao(text, bigint, text, text, text, text) from public;
grant execute on function public.save_subordinacao(text, bigint, text, text, text, text)
  to anon, authenticated, service_role;

-- A auditoria operacional usa o cadastro ativo; o vínculo com liderança não é
-- obrigatório e, quando existir, é copiado do próprio cadastro.
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
  v_setor text := lower(btrim(coalesce(p_type, '')));
  v_nome text := btrim(coalesce(p_team, ''));
  v_cargo text := btrim(coalesce(p_cargo, ''));
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha inválida';
  end if;

  if v_role not in ('supervisor', 'subordinado') then
    raise exception 'Tipo de auditado inválido';
  end if;

  if v_setor = '' or v_nome = '' then
    raise exception 'Setor e colaborador são obrigatórios';
  end if;

  if v_role = 'supervisor' then
    select lider.nome
    into v_nome
    from public.liderancas lider
    where lider.ativo
      and lider.cargo = 'Supervisor'
      and lower(btrim(lider.setor)) = v_setor
      and lower(btrim(lider.nome)) = lower(v_nome)
    limit 1;

    if v_nome is null then
      raise exception 'Supervisor não cadastrado na liderança deste setor';
    end if;

    v_supervisor := v_nome;
  else
    select cadastro.subordinado, cadastro.supervisor, cadastro.cargo
    into v_nome, v_supervisor, v_cargo
    from public.subordinacoes cadastro
    where cadastro.ativo
      and lower(btrim(cadastro.setor)) = v_setor
      and lower(btrim(cadastro.subordinado)) = lower(v_nome)
    limit 1;

    if v_nome is null then
      raise exception 'Colaborador operacional não cadastrado neste setor';
    end if;
  end if;

  insert into public.auditorias (
    audit_id, type, team, audit_date, cargo, score, total_ok, total_no, report,
    supervisor_name, audited_role
  ) values (
    p_audit_id, p_type, v_nome, p_audit_date, v_cargo, p_score, p_total_ok, p_total_no,
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

revoke execute on function public.save_auditoria_contextual(
  text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text
) from public;
grant execute on function public.save_auditoria_contextual(
  text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text
) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
