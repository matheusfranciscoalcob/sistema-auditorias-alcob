-- Auditorias vinculadas representam a origem da ação e podem pertencer a um
-- setor diferente daquele onde a melhoria será implementada.
create or replace function public.save_plano_acao_5w2h_v3(
  p_password text,
  p_id bigint,
  p_setor text,
  p_supervisores text[],
  p_auditoria_ids bigint[],
  p_sugestao_id bigint,
  p_o_que text,
  p_por_que text,
  p_onde text,
  p_quando date,
  p_quem text,
  p_como text,
  p_quanto text,
  p_status text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_setor text := btrim(coalesce(p_setor, ''));
  v_auditoria_ids bigint[];
  v_primeira_auditoria bigint;
  v_auditoria_origem text;
  v_sugestao_anterior bigint;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if p_id is null or v_setor = '' or nullif(btrim(p_o_que), '') is null then
    raise exception 'Setor e ação são obrigatórios';
  end if;

  if coalesce(nullif(btrim(p_status), ''), 'Pendente') not in ('Pendente', 'Em andamento', 'Concluído') then
    raise exception 'Status do plano de ação inválido';
  end if;

  if p_sugestao_id is not null and not exists (
    select 1
    from public.sugestoes_melhoria sugestao
    where sugestao.id = p_sugestao_id
  ) then
    raise exception 'Sugestão de melhoria não encontrada';
  end if;

  select plano.sugestao_id
  into v_sugestao_anterior
  from public.planos_acao_5w2h plano
  where plano.id = p_id;

  select coalesce(array_agg(distinct id order by id), array[]::bigint[])
  into v_auditoria_ids
  from unnest(coalesce(p_auditoria_ids, array[]::bigint[])) as selecionada(id)
  where id is not null;

  if exists (
    select 1
    from unnest(v_auditoria_ids) selecionada(id)
    left join public.auditorias auditoria on auditoria.audit_id = selecionada.id
    where auditoria.audit_id is null
  ) then
    raise exception 'Todas as auditorias vinculadas devem existir no sistema';
  end if;

  select selecionada.id
  into v_primeira_auditoria
  from unnest(v_auditoria_ids) selecionada(id)
  join public.auditorias auditoria on auditoria.audit_id = selecionada.id
  order by auditoria.audit_date desc, selecionada.id desc
  limit 1;

  if v_primeira_auditoria is not null then
    select concat(
      case auditoria.type
        when 'historico_p3' then 'Processo 3'
        when 'historico_p4' then 'Processo 4'
        else auditoria.type
      end,
      ' — ', auditoria.team,
      ' — ', to_char(auditoria.audit_date, 'DD/MM/YYYY'),
      ' — ', to_char(auditoria.score, 'FM990D00'), '%'
    )
    into v_auditoria_origem
    from public.auditorias auditoria
    where auditoria.audit_id = v_primeira_auditoria;
  end if;

  insert into public.planos_acao_5w2h (
    id, setor, auditoria_id, auditoria_origem, sugestao_id, o_que, por_que, onde,
    quando, quem, como, quanto, status, updated_at
  ) values (
    p_id, v_setor, v_primeira_auditoria, v_auditoria_origem, p_sugestao_id,
    btrim(p_o_que), nullif(btrim(p_por_que), ''), nullif(btrim(p_onde), ''),
    p_quando, nullif(btrim(p_quem), ''), nullif(btrim(p_como), ''),
    nullif(btrim(p_quanto), ''), coalesce(nullif(btrim(p_status), ''), 'Pendente'), now()
  )
  on conflict (id) do update set
    setor = excluded.setor,
    auditoria_id = excluded.auditoria_id,
    auditoria_origem = excluded.auditoria_origem,
    sugestao_id = excluded.sugestao_id,
    o_que = excluded.o_que,
    por_que = excluded.por_que,
    onde = excluded.onde,
    quando = excluded.quando,
    quem = excluded.quem,
    como = excluded.como,
    quanto = excluded.quanto,
    status = excluded.status,
    updated_at = now();

  delete from public.planos_acao_supervisores where plano_id = p_id;
  insert into public.planos_acao_supervisores (plano_id, supervisor)
  select p_id, min(btrim(selecionado.nome))
  from unnest(coalesce(p_supervisores, array[]::text[])) selecionado(nome)
  where nullif(btrim(selecionado.nome), '') is not null
  group by lower(btrim(selecionado.nome));

  delete from public.planos_acao_auditorias where plano_id = p_id;
  insert into public.planos_acao_auditorias (plano_id, auditoria_id)
  select p_id, selecionada.id
  from unnest(v_auditoria_ids) selecionada(id);

  if v_sugestao_anterior is distinct from p_sugestao_id then
    perform public.sincronizar_status_sugestao_plano(v_sugestao_anterior);
  end if;
  perform public.sincronizar_status_sugestao_plano(p_sugestao_id);

  return p_id;
end;
$$;

revoke execute on function public.save_plano_acao_5w2h_v3(
  text, bigint, text, text[], bigint[], bigint, text, text, text,
  date, text, text, text, text
) from public;

grant execute on function public.save_plano_acao_5w2h_v3(
  text, bigint, text, text[], bigint[], bigint, text, text, text,
  date, text, text, text, text
) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
