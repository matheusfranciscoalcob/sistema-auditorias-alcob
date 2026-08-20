begin;

alter table public.sugestoes_melhoria_status_historico
  drop constraint if exists sugestoes_melhoria_status_historico_status_check;

alter table public.sugestoes_melhoria_status_historico
  add constraint sugestoes_melhoria_status_historico_status_check
  check (status in (
    'Aguardando avaliação',
    'Registrada',
    'Em análise',
    'Aprovada',
    'Em implementação',
    'Concluída',
    'Não aprovada'
  ));

create or replace function public.enviar_sugestao_kaizen(
  p_titulo text,
  p_descricao text,
  p_setor text,
  p_autores text[]
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_titulo text := btrim(coalesce(p_titulo, ''));
  v_descricao text := btrim(coalesce(p_descricao, ''));
  v_setor text := coalesce(nullif(btrim(coalesce(p_setor, '')), ''), 'a_definir');
  v_autores text[] := coalesce(p_autores, array[]::text[]);
begin
  if v_titulo = '' or v_descricao = '' then
    raise exception 'Preencha titulo e descricao';
  end if;

  if length(v_titulo) > 180 or length(v_descricao) > 5000 then
    raise exception 'Titulo ou descricao excede o limite permitido';
  end if;

  if v_setor not in (
    'a_definir','forno','laminacao','laboratorio','engenharia','prensa','caldeiraria',
    'mecanica','eletrica','lavador','refratario','pcp','comercial','financeiro',
    'compras','rh','almoxarifado','ti','seguranca','manutencao_veiculos'
  ) then
    raise exception 'Setor de implementacao invalido';
  end if;

  if cardinality(v_autores) > 5 then
    raise exception 'Selecione no maximo cinco colaboradores como autores';
  end if;

  if exists (
    select 1
    from unnest(v_autores) selecionado(token)
    where selecionado.token !~ '^(lideranca|operacional):[0-9]+$'
  ) then
    raise exception 'Existe um autor invalido na selecao';
  end if;

  if exists (
    select 1
    from unnest(v_autores) selecionado(token)
    where case split_part(selecionado.token, ':', 1)
      when 'lideranca' then not exists (
        select 1
        from public.liderancas lider
        where lider.id = split_part(selecionado.token, ':', 2)::bigint
          and lider.ativo
      )
      when 'operacional' then not exists (
        select 1
        from public.subordinacoes colaborador
        where colaborador.id = split_part(selecionado.token, ':', 2)::bigint
          and colaborador.ativo
      )
      else true
    end
  ) then
    raise exception 'Todos os autores precisam estar cadastrados e ativos';
  end if;

  insert into public.sugestoes_melhoria (titulo, descricao, status, setor, origem)
  values (v_titulo, v_descricao, 'Aguardando avaliação', v_setor, 'kaizen')
  returning id into v_id;

  insert into public.sugestoes_melhoria_autores (
    sugestao_id, origem, origem_id, nome, cargo, setor
  )
  select distinct on (lower(btrim(pessoa.nome)))
    v_id, pessoa.origem, pessoa.origem_id, pessoa.nome, pessoa.cargo, pessoa.setor
  from (
    select
      'lideranca'::text as origem,
      lider.id as origem_id,
      lider.nome,
      lider.cargo,
      lider.setor
    from unnest(v_autores) selecionado(token)
    join public.liderancas lider
      on split_part(selecionado.token, ':', 1) = 'lideranca'
     and lider.id = split_part(selecionado.token, ':', 2)::bigint
     and lider.ativo

    union all

    select
      'operacional'::text,
      colaborador.id,
      colaborador.subordinado,
      colaborador.cargo,
      colaborador.setor
    from unnest(v_autores) selecionado(token)
    join public.subordinacoes colaborador
      on split_part(selecionado.token, ':', 1) = 'operacional'
     and colaborador.id = split_part(selecionado.token, ':', 2)::bigint
     and colaborador.ativo
  ) pessoa
  order by lower(btrim(pessoa.nome)), pessoa.origem, pessoa.origem_id;

  insert into public.sugestoes_melhoria_status_historico (
    sugestao_id, status, observacao
  )
  values (
    v_id,
    'Aguardando avaliação',
    'Kaizen enviado para avaliação da Engenharia.'
  );

  return v_id;
end;
$$;

revoke all on function public.enviar_sugestao_kaizen(text, text, text, text[]) from public;
grant execute on function public.enviar_sugestao_kaizen(text, text, text, text[]) to anon;

notify pgrst, 'reload schema';

commit;
