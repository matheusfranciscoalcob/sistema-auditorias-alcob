-- Registra o setor de implementação da sugestão e mantém compatibilidade com o RPC anterior.
alter table public.sugestoes_melhoria
  add column if not exists setor text;

-- Para o acervo atual, a auditoria de origem é a referência mais direta do local
-- de implementação. Na ausência dela, usa-se o setor do primeiro autor cadastrado.
update public.sugestoes_melhoria sugestao
set setor = coalesce(
  (
    select case auditoria.type
      when 'historico_p3' then 'forno'
      when 'historico_p4' then 'laminacao'
      else auditoria.type
    end
    from public.sugestoes_melhoria_auditorias vinculo
    join public.auditorias auditoria
      on auditoria.audit_id = vinculo.auditoria_id
    where vinculo.sugestao_id = sugestao.id
    order by auditoria.audit_date desc, auditoria.audit_id desc
    limit 1
  ),
  (
    select case autor.setor
      when 'qualidade_laboratorio' then 'laboratorio'
      else autor.setor
    end
    from public.sugestoes_melhoria_autores autor
    where autor.sugestao_id = sugestao.id
    order by autor.created_at, autor.nome
    limit 1
  ),
  'a_definir'
)
where sugestao.setor is null or btrim(sugestao.setor) = '';

alter table public.sugestoes_melhoria
  alter column setor set default 'a_definir',
  alter column setor set not null;

alter table public.sugestoes_melhoria
  drop constraint if exists sugestoes_melhoria_setor_check;

alter table public.sugestoes_melhoria
  add constraint sugestoes_melhoria_setor_check check (
    setor in (
      'a_definir', 'forno', 'laminacao', 'laboratorio', 'engenharia',
      'prensa', 'caldeiraria', 'mecanica', 'eletrica', 'lavador',
      'refratario', 'pcp', 'comercial', 'financeiro', 'compras', 'rh',
      'almoxarifado', 'ti', 'seguranca', 'manutencao_veiculos'
    )
  );

create index if not exists sugestoes_melhoria_setor_status_updated_idx
  on public.sugestoes_melhoria (setor, status, updated_at desc);

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
  coalesce(acoes.itens, '[]'::jsonb) as acoes,
  sugestao.setor
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

create or replace function public.save_sugestao_melhoria_v2(
  p_password text,
  p_id bigint,
  p_titulo text,
  p_descricao text,
  p_setor text,
  p_autores text[],
  p_auditoria_ids bigint[],
  p_status text,
  p_observacao_status text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_setor text := btrim(coalesce(p_setor, ''));
begin
  if v_setor = '' or v_setor = 'a_definir' then
    raise exception 'Selecione o setor onde a ideia será implementada';
  end if;

  if v_setor not in (
    'forno', 'laminacao', 'laboratorio', 'engenharia', 'prensa',
    'caldeiraria', 'mecanica', 'eletrica', 'lavador', 'refratario',
    'pcp', 'comercial', 'financeiro', 'compras', 'rh', 'almoxarifado',
    'ti', 'seguranca', 'manutencao_veiculos'
  ) then
    raise exception 'Setor de implementação inválido';
  end if;

  v_id := public.save_sugestao_melhoria(
    p_password,
    p_id,
    p_titulo,
    p_descricao,
    p_autores,
    p_auditoria_ids,
    p_status,
    p_observacao_status
  );

  update public.sugestoes_melhoria
  set setor = v_setor,
      updated_at = now()
  where id = v_id;

  return v_id;
end;
$$;

revoke execute on function public.save_sugestao_melhoria_v2(
  text, bigint, text, text, text, text[], bigint[], text, text
) from public;

grant execute on function public.save_sugestao_melhoria_v2(
  text, bigint, text, text, text, text[], bigint[], text, text
) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
