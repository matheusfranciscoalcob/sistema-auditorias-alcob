-- A subordinação passa a ser o cadastro único do colaborador operacional.
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

  select lider.nome
  into v_supervisor
  from public.liderancas lider
  where lider.ativo
    and lider.cargo = 'Supervisor'
    and lower(btrim(lider.setor)) = lower(v_setor)
    and lower(btrim(lider.nome)) = lower(v_supervisor)
  limit 1;

  if v_supervisor is null then
    raise exception 'Cadastre o supervisor na liderança e no mesmo setor antes de criar o vínculo';
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
      raise exception 'Vínculo de subordinação não encontrado';
    end if;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_subordinacao(text, bigint, text, text, text, text) from public;
grant execute on function public.save_subordinacao(text, bigint, text, text, text, text)
  to anon, authenticated, service_role;

-- A auditoria de operador só é liberada quando existir o vínculo ativo.
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
    if v_supervisor is null then
      raise exception 'O colaborador deve estar vinculado a um supervisor';
    end if;

    select vinculo.subordinado, vinculo.supervisor, vinculo.cargo
    into v_nome, v_supervisor, v_cargo
    from public.subordinacoes vinculo
    where vinculo.ativo
      and lower(btrim(vinculo.setor)) = v_setor
      and lower(btrim(vinculo.subordinado)) = lower(v_nome)
      and lower(btrim(vinculo.supervisor)) = lower(v_supervisor)
    limit 1;

    if v_nome is null then
      raise exception 'Vínculo ativo entre colaborador, supervisor e setor não encontrado';
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

-- Um superior pode estar em qualquer cargo estritamente acima do subordinado.
create or replace function public.save_lideranca(
  p_password text,
  p_id bigint,
  p_nome text,
  p_cargo text,
  p_setor text,
  p_superior_id bigint
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_nome text := btrim(coalesce(p_nome, ''));
  v_cargo text := btrim(coalesce(p_cargo, ''));
  v_setor text := btrim(coalesce(p_setor, ''));
  v_nivel integer;
  v_nivel_superior integer;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  v_nivel := case v_cargo
    when 'Supervisor' then 1
    when 'Gestor' then 2
    when 'Gerente' then 3
    when 'Diretor' then 4
    else null
  end;

  if v_nome = '' or v_setor = '' or v_nivel is null then
    raise exception 'Preencha nome, cargo e área/setor da liderança';
  end if;

  if v_cargo = 'Diretor' and p_superior_id is not null then
    raise exception 'Diretor é o nível mais alto e não pode possuir superior direto';
  end if;

  if p_superior_id is not null then
    if p_id is not null and p_superior_id = p_id then
      raise exception 'Uma pessoa não pode ser superior de si mesma';
    end if;

    select case superior.cargo
      when 'Supervisor' then 1
      when 'Gestor' then 2
      when 'Gerente' then 3
      when 'Diretor' then 4
      else null
    end
    into v_nivel_superior
    from public.liderancas superior
    where superior.id = p_superior_id
      and superior.ativo;

    if v_nivel_superior is null then
      raise exception 'Superior direto não encontrado';
    end if;

    if v_nivel_superior <= v_nivel then
      raise exception 'O superior direto de % deve possuir um cargo hierarquicamente acima', v_cargo;
    end if;
  end if;

  if p_id is not null and exists (
    select 1
    from public.liderancas subordinado
    where subordinado.superior_id = p_id
      and subordinado.ativo
      and case subordinado.cargo
        when 'Supervisor' then 1
        when 'Gestor' then 2
        when 'Gerente' then 3
        when 'Diretor' then 4
        else 99
      end >= v_nivel
  ) then
    raise exception 'O novo cargo deve permanecer acima de todos os subordinados diretos já vinculados';
  end if;

  if p_id is null then
    insert into public.liderancas (nome, cargo, setor, superior_id)
    values (v_nome, v_cargo, v_setor, p_superior_id)
    returning id into v_id;
  else
    update public.liderancas
    set nome = v_nome,
        cargo = v_cargo,
        setor = v_setor,
        superior_id = p_superior_id,
        ativo = true,
        updated_at = now()
    where id = p_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Cadastro de liderança não encontrado';
    end if;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_lideranca(text, bigint, text, text, text, bigint) from public;
grant execute on function public.save_lideranca(text, bigint, text, text, text, bigint)
  to anon, authenticated, service_role;

-- Remove a fonte duplicada depois de trocar todas as validações que a utilizavam.
drop view if exists public.colaboradores_operacionais_publicos;
drop function if exists public.save_colaborador_operacional(text, bigint, text, text, text);
drop function if exists public.delete_colaborador_operacional(text, bigint);
drop table if exists public.colaboradores_operacionais;

notify pgrst, 'reload schema';
