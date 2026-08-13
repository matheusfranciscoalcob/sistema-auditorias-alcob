alter table public.subordinacoes
  add constraint subordinacoes_pessoas_distintas_check
  check (lower(btrim(supervisor)) <> lower(btrim(subordinado)));

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
  if v_role = 'subordinado' and not exists (
    select 1
    from public.subordinacoes s
    where s.ativo
      and lower(btrim(s.setor)) = lower(btrim(p_type))
      and lower(btrim(s.subordinado)) = lower(btrim(p_team))
      and lower(btrim(s.supervisor)) = lower(v_supervisor)
  ) then
    raise exception 'Vínculo ativo entre subordinado, supervisor e setor não encontrado';
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

revoke execute on function public.save_auditoria_contextual(
  text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text
) from public;
grant execute on function public.save_auditoria_contextual(
  text, bigint, text, text, date, text, numeric, integer, integer, jsonb, text, text
) to anon, authenticated, service_role;
