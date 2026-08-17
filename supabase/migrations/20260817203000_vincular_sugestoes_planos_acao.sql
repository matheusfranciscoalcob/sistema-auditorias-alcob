alter table public.planos_acao_5w2h
  add column if not exists sugestao_id bigint
  references public.sugestoes_melhoria(id) on delete set null;

create index if not exists planos_acao_5w2h_sugestao_idx
  on public.planos_acao_5w2h (sugestao_id)
  where sugestao_id is not null;

create or replace function public.sincronizar_status_sugestao_plano(
  p_sugestao_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status_anterior text;
  v_status_novo text;
  v_total_acoes integer;
  v_acoes_concluidas integer;
begin
  if p_sugestao_id is null then
    return;
  end if;

  select sugestao.status
  into v_status_anterior
  from public.sugestoes_melhoria sugestao
  where sugestao.id = p_sugestao_id;

  if v_status_anterior is null then
    return;
  end if;

  select
    count(*)::integer,
    count(*) filter (where plano.status = 'Concluído')::integer
  into v_total_acoes, v_acoes_concluidas
  from public.planos_acao_5w2h plano
  where plano.sugestao_id = p_sugestao_id;

  if v_total_acoes = 0 then
    if v_status_anterior not in ('Em implementação', 'Concluída') then
      return;
    end if;
    v_status_novo := 'Aprovada';
  elsif v_acoes_concluidas = v_total_acoes then
    v_status_novo := 'Concluída';
  else
    v_status_novo := 'Em implementação';
  end if;

  if v_status_anterior is distinct from v_status_novo then
    update public.sugestoes_melhoria
    set status = v_status_novo,
        updated_at = now()
    where id = p_sugestao_id;

    insert into public.sugestoes_melhoria_status_historico (
      sugestao_id, status, observacao
    ) values (
      p_sugestao_id,
      v_status_novo,
      case
        when v_status_novo = 'Em implementação'
          then 'Status atualizado automaticamente ao vincular a sugestão ao plano de ação 5W2H.'
        when v_status_novo = 'Concluída'
          then 'Status atualizado automaticamente: todas as ações 5W2H vinculadas foram concluídas.'
        else 'Status atualizado automaticamente após a remoção do último vínculo com o plano de ação.'
      end
    );
  end if;
end;
$$;

revoke execute on function public.sincronizar_status_sugestao_plano(bigint)
  from public, anon, authenticated;

create or replace view public.planos_acao_publicos
with (security_invoker = true)
as
select
  plano.id,
  plano.setor,
  plano.auditoria_id,
  plano.auditoria_origem,
  plano.o_que,
  plano.por_que,
  plano.onde,
  plano.quando,
  plano.quem,
  plano.como,
  plano.quanto,
  plano.status,
  plano.created_at,
  plano.updated_at,
  coalesce(supervisores.nomes, array[]::text[]) as supervisores,
  coalesce(auditorias.ids, array[]::bigint[]) as auditoria_ids,
  coalesce(auditorias.itens, '[]'::jsonb) as auditorias,
  plano.sugestao_id,
  sugestao.titulo as sugestao_titulo,
  sugestao.status as sugestao_status
from public.planos_acao_5w2h plano
left join public.sugestoes_melhoria sugestao
  on sugestao.id = plano.sugestao_id
left join lateral (
  select array_agg(vinculo.supervisor order by vinculo.supervisor) as nomes
  from public.planos_acao_supervisores vinculo
  where vinculo.plano_id = plano.id
) supervisores on true
left join lateral (
  select
    array_agg(vinculo.auditoria_id order by auditoria.audit_date desc, vinculo.auditoria_id desc) as ids,
    jsonb_agg(
      jsonb_build_object(
        'id', auditoria.audit_id,
        'type', auditoria.type,
        'team', auditoria.team,
        'date', auditoria.audit_date,
        'score', auditoria.score,
        'supervisorName', auditoria.supervisor_name,
        'auditedRole', auditoria.audited_role
      )
      order by auditoria.audit_date desc, vinculo.auditoria_id desc
    ) as itens
  from public.planos_acao_auditorias vinculo
  join public.auditoria_resultados auditoria
    on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.plano_id = plano.id
) auditorias on true;

revoke all on table public.planos_acao_publicos from public;
grant select on table public.planos_acao_publicos to anon, authenticated, service_role;

create or replace view public.sugestoes_melhoria_publicas
with (security_invoker = true)
as
select
  sugestao.id,
  sugestao.titulo,
  sugestao.descricao,
  sugestao.status,
  sugestao.created_at,
  sugestao.updated_at,
  coalesce(autores.itens, '[]'::jsonb) as autores,
  coalesce(auditorias.ids, array[]::bigint[]) as auditoria_ids,
  coalesce(auditorias.itens, '[]'::jsonb) as auditorias,
  coalesce(historico.itens, '[]'::jsonb) as historico,
  coalesce(acoes.ids, array[]::bigint[]) as acao_ids,
  coalesce(acoes.itens, '[]'::jsonb) as acoes
from public.sugestoes_melhoria sugestao
left join lateral (
  select jsonb_agg(
    jsonb_build_object(
      'origem', autor.origem,
      'origemId', autor.origem_id,
      'nome', autor.nome,
      'cargo', autor.cargo,
      'setor', autor.setor
    )
    order by autor.nome
  ) as itens
  from public.sugestoes_melhoria_autores autor
  where autor.sugestao_id = sugestao.id
) autores on true
left join lateral (
  select
    array_agg(vinculo.auditoria_id order by auditoria.audit_date desc, vinculo.auditoria_id desc) as ids,
    jsonb_agg(
      jsonb_build_object(
        'id', auditoria.audit_id,
        'type', auditoria.type,
        'team', auditoria.team,
        'date', auditoria.audit_date,
        'score', auditoria.score,
        'supervisorName', auditoria.supervisor_name,
        'auditedRole', auditoria.audited_role
      )
      order by auditoria.audit_date desc, vinculo.auditoria_id desc
    ) as itens
  from public.sugestoes_melhoria_auditorias vinculo
  join public.auditoria_resultados auditoria
    on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.sugestao_id = sugestao.id
) auditorias on true
left join lateral (
  select jsonb_agg(
    jsonb_build_object(
      'status', evento.status,
      'observacao', evento.observacao,
      'data', evento.created_at
    )
    order by evento.created_at desc, evento.id desc
  ) as itens
  from public.sugestoes_melhoria_status_historico evento
  where evento.sugestao_id = sugestao.id
) historico on true
left join lateral (
  select
    array_agg(plano.id order by plano.created_at desc, plano.id desc) as ids,
    jsonb_agg(
      jsonb_build_object(
        'id', plano.id,
        'setor', plano.setor,
        'acao', plano.o_que,
        'status', plano.status,
        'prazo', plano.quando
      )
      order by plano.created_at desc, plano.id desc
    ) as itens
  from public.planos_acao_5w2h plano
  where plano.sugestao_id = sugestao.id
) acoes on true;

revoke all on table public.sugestoes_melhoria_publicas from public;
grant select on table public.sugestoes_melhoria_publicas to anon, authenticated, service_role;

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
       or case auditoria.type
            when 'historico_p3' then 'forno'
            when 'historico_p4' then 'laminacao'
            else auditoria.type
          end <> v_setor
  ) then
    raise exception 'Todas as auditorias vinculadas devem existir e pertencer ao setor da ação';
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

create or replace function public.delete_plano_acao_5w2h(
  p_id bigint,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_afetados integer;
  v_sugestao_id bigint;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  select plano.sugestao_id
  into v_sugestao_id
  from public.planos_acao_5w2h plano
  where plano.id = p_id;

  delete from public.planos_acao_5w2h where id = p_id;
  get diagnostics v_afetados = row_count;

  perform public.sincronizar_status_sugestao_plano(v_sugestao_id);
  return v_afetados > 0;
end;
$$;

revoke execute on function public.save_plano_acao_5w2h_v3(
  text, bigint, text, text[], bigint[], bigint, text, text, text, date, text, text, text, text
) from public;
grant execute on function public.save_plano_acao_5w2h_v3(
  text, bigint, text, text[], bigint[], bigint, text, text, text, date, text, text, text, text
) to anon, authenticated, service_role;

revoke execute on function public.delete_plano_acao_5w2h(bigint, text) from public;
grant execute on function public.delete_plano_acao_5w2h(bigint, text)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
