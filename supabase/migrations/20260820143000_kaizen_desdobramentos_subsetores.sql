-- Evolucao integrada: responsaveis e desdobramentos 5W2H, fluxo Kaizen,
-- origem das sugestoes e subsetores operacionais da Laminacao.

-- A coluna e a visao publica precisam existir antes das visoes 5W2H e
-- sugestoes, que incluem o subsetor nas auditorias vinculadas.
alter table public.auditorias add column if not exists subsetor text;

create or replace view public.auditoria_resultados as
select
  audit_id, created_at, type, team, audit_date, cargo, score, total_ok, total_no,
  supervisor_name, audited_role, subsetor
from public.auditorias;

grant select on public.auditoria_resultados to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5W2H: responsaveis cadastrados e acoes subordinadas
-- ---------------------------------------------------------------------------

alter table public.planos_acao_5w2h
  add column if not exists acao_pai_id bigint;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'planos_acao_5w2h_acao_pai_id_fkey'
      and conrelid = 'public.planos_acao_5w2h'::regclass
  ) then
    alter table public.planos_acao_5w2h
      add constraint planos_acao_5w2h_acao_pai_id_fkey
      foreign key (acao_pai_id) references public.planos_acao_5w2h(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists planos_acao_5w2h_acao_pai_idx
  on public.planos_acao_5w2h (acao_pai_id)
  where acao_pai_id is not null;

create table if not exists public.planos_acao_responsaveis (
  plano_id bigint not null references public.planos_acao_5w2h(id) on delete cascade,
  origem text not null check (origem in ('lideranca', 'operacional')),
  origem_id bigint not null,
  nome text not null check (btrim(nome) <> ''),
  cargo text not null check (btrim(cargo) <> ''),
  setor text not null check (btrim(setor) <> ''),
  created_at timestamptz not null default now(),
  primary key (plano_id, origem, origem_id)
);

create index if not exists planos_acao_responsaveis_nome_idx
  on public.planos_acao_responsaveis (lower(nome), plano_id);

alter table public.planos_acao_responsaveis enable row level security;
revoke all on table public.planos_acao_responsaveis from anon, authenticated;

-- Preserva o campo textual antigo e cria vinculos quando o nome coincide
-- exatamente com uma pessoa ativa cadastrada.
insert into public.planos_acao_responsaveis (plano_id, origem, origem_id, nome, cargo, setor)
select plano.id, pessoa.origem, pessoa.origem_id, pessoa.nome, pessoa.cargo, pessoa.setor
from public.planos_acao_5w2h plano
join lateral (
  select 'lideranca'::text origem, lider.id origem_id, lider.nome, lider.cargo, lider.setor
  from public.liderancas lider
  where lider.ativo and lower(btrim(lider.nome)) = lower(btrim(plano.quem))
  union all
  select 'operacional'::text, colaborador.id, colaborador.subordinado, colaborador.cargo, colaborador.setor
  from public.subordinacoes colaborador
  where colaborador.ativo and lower(btrim(colaborador.subordinado)) = lower(btrim(plano.quem))
) pessoa on true
where nullif(btrim(plano.quem), '') is not null
on conflict do nothing;

create or replace function public.save_plano_acao_5w2h_v4(
  p_password text,
  p_id bigint,
  p_setor text,
  p_supervisores text[],
  p_auditoria_ids bigint[],
  p_sugestao_id bigint,
  p_acao_pai_id bigint,
  p_responsaveis text[],
  p_o_que text,
  p_por_que text,
  p_onde text,
  p_quando date,
  p_como text,
  p_quanto text,
  p_status text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_setor text := btrim(coalesce(p_setor, ''));
  v_quem text;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa invalida';
  end if;

  if p_id is null or v_setor = '' or nullif(btrim(p_o_que), '') is null then
    raise exception 'Setor e acao sao obrigatorios';
  end if;

  if coalesce(cardinality(p_responsaveis), 0) = 0 then
    raise exception 'Selecione pelo menos um colaborador cadastrado no campo Quem';
  end if;

  if exists (
    select 1 from unnest(p_responsaveis) selecionado(token)
    where selecionado.token !~ '^(lideranca|operacional):[0-9]+$'
  ) then
    raise exception 'Existe um responsavel invalido na selecao';
  end if;

  if exists (
    select 1
    from unnest(p_responsaveis) selecionado(token)
    where case split_part(selecionado.token, ':', 1)
      when 'lideranca' then not exists (
        select 1 from public.liderancas lider
        where lider.id = split_part(selecionado.token, ':', 2)::bigint and lider.ativo
      )
      when 'operacional' then not exists (
        select 1 from public.subordinacoes colaborador
        where colaborador.id = split_part(selecionado.token, ':', 2)::bigint and colaborador.ativo
      )
      else true
    end
  ) then
    raise exception 'Todos os responsaveis precisam permanecer cadastrados e ativos';
  end if;

  if p_acao_pai_id is not null then
    if p_acao_pai_id = p_id then
      raise exception 'Uma acao nao pode ser subordinada a ela mesma';
    end if;

    if not exists (
      select 1 from public.planos_acao_5w2h pai
      where pai.id = p_acao_pai_id and pai.setor = v_setor
    ) then
      raise exception 'A acao inicial deve existir e pertencer ao mesmo setor';
    end if;

    if exists (
      with recursive descendentes as (
        select filho.id
        from public.planos_acao_5w2h filho
        where filho.acao_pai_id = p_id
        union all
        select filho.id
        from public.planos_acao_5w2h filho
        join descendentes d on filho.acao_pai_id = d.id
      )
      select 1 from descendentes where id = p_acao_pai_id
    ) then
      raise exception 'Este vinculo criaria um ciclo entre as acoes';
    end if;
  end if;

  select string_agg(pessoa.nome, ', ' order by pessoa.nome)
  into v_quem
  from (
    select distinct on (lower(btrim(base.nome))) base.nome
    from (
      select lider.nome
      from unnest(p_responsaveis) selecionado(token)
      join public.liderancas lider
        on split_part(selecionado.token, ':', 1) = 'lideranca'
       and lider.id = split_part(selecionado.token, ':', 2)::bigint
       and lider.ativo
      union all
      select colaborador.subordinado
      from unnest(p_responsaveis) selecionado(token)
      join public.subordinacoes colaborador
        on split_part(selecionado.token, ':', 1) = 'operacional'
       and colaborador.id = split_part(selecionado.token, ':', 2)::bigint
       and colaborador.ativo
    ) base
    order by lower(btrim(base.nome)), base.nome
  ) pessoa;

  perform public.save_plano_acao_5w2h_v3(
    p_password, p_id, v_setor, p_supervisores, p_auditoria_ids, p_sugestao_id,
    p_o_que, p_por_que, p_onde, p_quando, v_quem, p_como, p_quanto, p_status
  );

  update public.planos_acao_5w2h
  set acao_pai_id = p_acao_pai_id,
      updated_at = now()
  where id = p_id;

  delete from public.planos_acao_responsaveis where plano_id = p_id;

  insert into public.planos_acao_responsaveis (
    plano_id, origem, origem_id, nome, cargo, setor
  )
  select distinct on (pessoa.origem, pessoa.origem_id)
    p_id, pessoa.origem, pessoa.origem_id, pessoa.nome, pessoa.cargo, pessoa.setor
  from (
    select 'lideranca'::text origem, lider.id origem_id, lider.nome, lider.cargo, lider.setor
    from unnest(p_responsaveis) selecionado(token)
    join public.liderancas lider
      on split_part(selecionado.token, ':', 1) = 'lideranca'
     and lider.id = split_part(selecionado.token, ':', 2)::bigint
     and lider.ativo
    union all
    select 'operacional'::text, colaborador.id, colaborador.subordinado, colaborador.cargo, colaborador.setor
    from unnest(p_responsaveis) selecionado(token)
    join public.subordinacoes colaborador
      on split_part(selecionado.token, ':', 1) = 'operacional'
     and colaborador.id = split_part(selecionado.token, ':', 2)::bigint
     and colaborador.ativo
  ) pessoa
  order by pessoa.origem, pessoa.origem_id;

  return p_id;
end;
$$;

revoke all on function public.save_plano_acao_5w2h_v4(
  text,bigint,text,text[],bigint[],bigint,bigint,text[],text,text,text,date,text,text,text
) from public;
grant execute on function public.save_plano_acao_5w2h_v4(
  text,bigint,text,text[],bigint[],bigint,bigint,text[],text,text,text,date,text,text,text
) to anon, authenticated;

create or replace view public.planos_acao_publicos as
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
  sugestao.status as sugestao_status,
  plano.acao_pai_id,
  pai.o_que as acao_pai_o_que,
  pai.status as acao_pai_status,
  coalesce(responsaveis.tokens, array[]::text[]) as responsavel_tokens,
  coalesce(responsaveis.itens, '[]'::jsonb) as responsaveis
from public.planos_acao_5w2h plano
left join public.planos_acao_5w2h pai on pai.id = plano.acao_pai_id
left join public.sugestoes_melhoria sugestao on sugestao.id = plano.sugestao_id
left join lateral (
  select array_agg(vinculo.supervisor order by vinculo.supervisor) nomes
  from public.planos_acao_supervisores vinculo
  where vinculo.plano_id = plano.id
) supervisores on true
left join lateral (
  select
    array_agg(vinculo.auditoria_id order by auditoria.audit_date desc, vinculo.auditoria_id desc) ids,
    jsonb_agg(jsonb_build_object(
      'id', auditoria.audit_id, 'type', auditoria.type, 'team', auditoria.team,
      'date', auditoria.audit_date, 'score', auditoria.score,
      'supervisorName', auditoria.supervisor_name, 'auditedRole', auditoria.audited_role,
      'subsetor', auditoria.subsetor
    ) order by auditoria.audit_date desc, vinculo.auditoria_id desc) itens
  from public.planos_acao_auditorias vinculo
  join public.auditoria_resultados auditoria on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.plano_id = plano.id
) auditorias on true
left join lateral (
  select
    array_agg(responsavel.origem || ':' || responsavel.origem_id::text order by responsavel.nome) tokens,
    jsonb_agg(jsonb_build_object(
      'origem', responsavel.origem, 'origemId', responsavel.origem_id,
      'nome', responsavel.nome, 'cargo', responsavel.cargo, 'setor', responsavel.setor
    ) order by responsavel.nome) itens
  from public.planos_acao_responsaveis responsavel
  where responsavel.plano_id = plano.id
) responsaveis on true;

grant select on public.planos_acao_publicos to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Sugestoes: origem, entrada publica Kaizen e avaliacao pela Engenharia
-- ---------------------------------------------------------------------------

alter table public.sugestoes_melhoria
  add column if not exists origem text;

update public.sugestoes_melhoria sugestao
set origem = 'auditoria'
where exists (
  select 1 from public.sugestoes_melhoria_auditorias vinculo
  where vinculo.sugestao_id = sugestao.id
);

alter table public.sugestoes_melhoria
  drop constraint if exists sugestoes_melhoria_status_check;
alter table public.sugestoes_melhoria
  add constraint sugestoes_melhoria_status_check
  check (status in (
    'Aguardando avaliação', 'Registrada', 'Em análise', 'Aprovada',
    'Em implementação', 'Concluída', 'Não aprovada'
  ));

alter table public.sugestoes_melhoria
  drop constraint if exists sugestoes_melhoria_origem_check;
alter table public.sugestoes_melhoria
  add constraint sugestoes_melhoria_origem_check
  check (origem is null or origem in (
    'auditoria', 'kaizen', 'avaliacao_processo', 'conversa', 'reuniao'
  ));

create index if not exists sugestoes_melhoria_origem_updated_idx
  on public.sugestoes_melhoria (origem, updated_at desc);

create or replace function public.save_sugestao_melhoria(
  p_password text,
  p_id bigint,
  p_titulo text,
  p_descricao text,
  p_autores text[],
  p_auditoria_ids bigint[],
  p_status text,
  p_observacao_status text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_titulo text := btrim(coalesce(p_titulo, ''));
  v_descricao text := btrim(coalesce(p_descricao, ''));
  v_status text := coalesce(nullif(btrim(p_status), ''), 'Registrada');
  v_observacao text := nullif(btrim(coalesce(p_observacao_status, '')), '');
  v_status_anterior text;
  v_auditoria_ids bigint[];
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa invalida';
  end if;
  if v_titulo = '' or v_descricao = '' then
    raise exception 'Titulo e descricao da sugestao sao obrigatorios';
  end if;
  if length(v_titulo) > 180 or length(v_descricao) > 5000 then
    raise exception 'Titulo ou descricao excede o limite permitido';
  end if;
  if v_status not in (
    'Aguardando avaliação', 'Registrada', 'Em análise', 'Aprovada',
    'Em implementação', 'Concluída', 'Não aprovada'
  ) then
    raise exception 'Status da sugestao invalido';
  end if;
  if coalesce(cardinality(p_autores), 0) = 0 then
    raise exception 'Selecione pelo menos um colaborador como autor da ideia';
  end if;
  if exists (
    select 1 from unnest(p_autores) selecionado(token)
    where selecionado.token !~ '^(lideranca|operacional):[0-9]+$'
  ) then
    raise exception 'Existe um autor invalido na selecao';
  end if;
  if exists (
    select 1
    from unnest(p_autores) selecionado(token)
    where case split_part(selecionado.token, ':', 1)
      when 'lideranca' then not exists (
        select 1 from public.liderancas lider
        where lider.id = split_part(selecionado.token, ':', 2)::bigint and lider.ativo
      )
      when 'operacional' then not exists (
        select 1 from public.subordinacoes colaborador
        where colaborador.id = split_part(selecionado.token, ':', 2)::bigint and colaborador.ativo
      )
      else true
    end
  ) then
    raise exception 'Todos os autores precisam permanecer cadastrados e ativos';
  end if;

  select coalesce(array_agg(distinct id order by id), array[]::bigint[])
  into v_auditoria_ids
  from unnest(coalesce(p_auditoria_ids, array[]::bigint[])) selecionada(id)
  where id is not null;

  if exists (
    select 1 from unnest(v_auditoria_ids) selecionada(id)
    left join public.auditorias auditoria on auditoria.audit_id = selecionada.id
    where auditoria.audit_id is null
  ) then
    raise exception 'Uma das auditorias de origem nao foi encontrada';
  end if;

  if p_id is null then
    insert into public.sugestoes_melhoria (titulo, descricao, status)
    values (v_titulo, v_descricao, v_status)
    returning id into v_id;
  else
    select status into v_status_anterior
    from public.sugestoes_melhoria where id = p_id;
    if v_status_anterior is null then
      raise exception 'Sugestao de melhoria nao encontrada';
    end if;
    update public.sugestoes_melhoria
    set titulo = v_titulo, descricao = v_descricao, status = v_status, updated_at = now()
    where id = p_id returning id into v_id;
  end if;

  delete from public.sugestoes_melhoria_autores where sugestao_id = v_id;
  insert into public.sugestoes_melhoria_autores (
    sugestao_id, origem, origem_id, nome, cargo, setor
  )
  select distinct on (lower(btrim(pessoa.nome)))
    v_id, pessoa.origem, pessoa.origem_id, pessoa.nome, pessoa.cargo, pessoa.setor
  from (
    select 'lideranca'::text origem, lider.id origem_id, lider.nome, lider.cargo, lider.setor
    from unnest(p_autores) selecionado(token)
    join public.liderancas lider
      on split_part(selecionado.token, ':', 1) = 'lideranca'
     and lider.id = split_part(selecionado.token, ':', 2)::bigint and lider.ativo
    union all
    select 'operacional'::text, colaborador.id, colaborador.subordinado, colaborador.cargo, colaborador.setor
    from unnest(p_autores) selecionado(token)
    join public.subordinacoes colaborador
      on split_part(selecionado.token, ':', 1) = 'operacional'
     and colaborador.id = split_part(selecionado.token, ':', 2)::bigint and colaborador.ativo
  ) pessoa
  order by lower(btrim(pessoa.nome)), pessoa.origem, pessoa.origem_id;

  if not exists (
    select 1 from public.sugestoes_melhoria_autores autor where autor.sugestao_id = v_id
  ) then
    raise exception 'Selecione pelo menos um colaborador como autor da ideia';
  end if;

  delete from public.sugestoes_melhoria_auditorias where sugestao_id = v_id;
  insert into public.sugestoes_melhoria_auditorias (sugestao_id, auditoria_id)
  select v_id, selecionada.id from unnest(v_auditoria_ids) selecionada(id);

  if p_id is null or v_status_anterior is distinct from v_status or v_observacao is not null then
    insert into public.sugestoes_melhoria_status_historico (sugestao_id, status, observacao)
    values (
      v_id, v_status,
      coalesce(v_observacao, case when p_id is null then 'Sugestao registrada no sistema.' end)
    );
  end if;
  return v_id;
end;
$$;

create or replace function public.save_sugestao_melhoria_v3(
  p_password text,
  p_id bigint,
  p_titulo text,
  p_descricao text,
  p_setor text,
  p_origem text,
  p_autores text[],
  p_auditoria_ids bigint[],
  p_status text,
  p_observacao_status text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_origem text := nullif(btrim(coalesce(p_origem, '')), '');
begin
  if coalesce(cardinality(p_auditoria_ids), 0) > 0 then
    v_origem := 'auditoria';
  end if;
  if v_origem is not null and v_origem not in (
    'auditoria', 'kaizen', 'avaliacao_processo', 'conversa', 'reuniao'
  ) then
    raise exception 'Origem da sugestao invalida';
  end if;

  v_id := public.save_sugestao_melhoria_v2(
    p_password, p_id, p_titulo, p_descricao, p_setor, p_autores,
    p_auditoria_ids, p_status, p_observacao_status
  );
  update public.sugestoes_melhoria
  set origem = v_origem, updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

revoke all on function public.save_sugestao_melhoria_v3(
  text,bigint,text,text,text,text,text[],bigint[],text,text
) from public;
grant execute on function public.save_sugestao_melhoria_v3(
  text,bigint,text,text,text,text,text[],bigint[],text,text
) to anon, authenticated;

create or replace function public.enviar_sugestao_kaizen(
  p_titulo text,
  p_descricao text,
  p_setor text,
  p_autores text[]
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_titulo text := btrim(coalesce(p_titulo, ''));
  v_descricao text := btrim(coalesce(p_descricao, ''));
  v_setor text := btrim(coalesce(p_setor, ''));
begin
  if v_titulo = '' or v_descricao = '' or v_setor = '' then
    raise exception 'Preencha titulo, descricao e setor';
  end if;
  if length(v_titulo) > 180 or length(v_descricao) > 5000 then
    raise exception 'Titulo ou descricao excede o limite permitido';
  end if;
  if v_setor not in (
    'forno','laminacao','laboratorio','engenharia','prensa','caldeiraria','mecanica',
    'eletrica','lavador','refratario','pcp','comercial','financeiro','compras','rh',
    'almoxarifado','ti','seguranca','manutencao_veiculos'
  ) then
    raise exception 'Setor de implementacao invalido';
  end if;
  if coalesce(cardinality(p_autores), 0) = 0 or cardinality(p_autores) > 5 then
    raise exception 'Selecione de um a cinco colaboradores como autores';
  end if;
  if exists (
    select 1 from unnest(p_autores) selecionado(token)
    where selecionado.token !~ '^(lideranca|operacional):[0-9]+$'
  ) then
    raise exception 'Existe um autor invalido na selecao';
  end if;
  if exists (
    select 1
    from unnest(p_autores) selecionado(token)
    where case split_part(selecionado.token, ':', 1)
      when 'lideranca' then not exists (
        select 1 from public.liderancas lider
        where lider.id = split_part(selecionado.token, ':', 2)::bigint and lider.ativo
      )
      when 'operacional' then not exists (
        select 1 from public.subordinacoes colaborador
        where colaborador.id = split_part(selecionado.token, ':', 2)::bigint and colaborador.ativo
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
    select 'lideranca'::text origem, lider.id origem_id, lider.nome, lider.cargo, lider.setor
    from unnest(p_autores) selecionado(token)
    join public.liderancas lider
      on split_part(selecionado.token, ':', 1) = 'lideranca'
     and lider.id = split_part(selecionado.token, ':', 2)::bigint and lider.ativo
    union all
    select 'operacional'::text, colaborador.id, colaborador.subordinado, colaborador.cargo, colaborador.setor
    from unnest(p_autores) selecionado(token)
    join public.subordinacoes colaborador
      on split_part(selecionado.token, ':', 1) = 'operacional'
     and colaborador.id = split_part(selecionado.token, ':', 2)::bigint and colaborador.ativo
  ) pessoa
  order by lower(btrim(pessoa.nome)), pessoa.origem, pessoa.origem_id;

  insert into public.sugestoes_melhoria_status_historico (sugestao_id, status, observacao)
  values (v_id, 'Aguardando avaliação', 'Kaizen enviado pelos colaboradores para avaliacao da Engenharia.');
  return v_id;
end;
$$;

revoke all on function public.enviar_sugestao_kaizen(text,text,text,text[]) from public;
grant execute on function public.enviar_sugestao_kaizen(text,text,text,text[]) to anon, authenticated;

create or replace function public.avaliar_sugestao_kaizen(
  p_password text,
  p_id bigint,
  p_aprovada boolean,
  p_observacao text
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text := case when p_aprovada then 'Registrada' else 'Não aprovada' end;
  v_observacao text := nullif(btrim(coalesce(p_observacao, '')), '');
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa invalida';
  end if;
  if not exists (
    select 1 from public.sugestoes_melhoria sugestao
    where sugestao.id = p_id
      and sugestao.origem = 'kaizen'
      and sugestao.status = 'Aguardando avaliação'
  ) then
    raise exception 'Kaizen nao encontrado ou ja avaliado';
  end if;
  update public.sugestoes_melhoria
  set status = v_status, updated_at = now()
  where id = p_id;
  insert into public.sugestoes_melhoria_status_historico (sugestao_id, status, observacao)
  values (
    p_id, v_status,
    coalesce(v_observacao, case when p_aprovada
      then 'Ideia avaliada pela Engenharia e registrada para acompanhamento.'
      else 'Ideia avaliada pela Engenharia e nao aprovada.' end)
  );
  return true;
end;
$$;

revoke all on function public.avaliar_sugestao_kaizen(text,bigint,boolean,text) from public;
grant execute on function public.avaliar_sugestao_kaizen(text,bigint,boolean,text) to anon, authenticated;

create or replace view public.sugestoes_melhoria_publicas as
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
  sugestao.setor,
  sugestao.origem
from public.sugestoes_melhoria sugestao
left join lateral (
  select jsonb_agg(jsonb_build_object(
    'origem', autor.origem, 'origemId', autor.origem_id,
    'nome', autor.nome, 'cargo', autor.cargo, 'setor', autor.setor
  ) order by autor.nome) itens
  from public.sugestoes_melhoria_autores autor
  where autor.sugestao_id = sugestao.id
) autores on true
left join lateral (
  select
    array_agg(vinculo.auditoria_id order by auditoria.audit_date desc, vinculo.auditoria_id desc) ids,
    jsonb_agg(jsonb_build_object(
      'id', auditoria.audit_id, 'type', auditoria.type, 'team', auditoria.team,
      'date', auditoria.audit_date, 'score', auditoria.score,
      'supervisorName', auditoria.supervisor_name, 'auditedRole', auditoria.audited_role,
      'subsetor', auditoria.subsetor
    ) order by auditoria.audit_date desc, vinculo.auditoria_id desc) itens
  from public.sugestoes_melhoria_auditorias vinculo
  join public.auditoria_resultados auditoria on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.sugestao_id = sugestao.id
) auditorias on true
left join lateral (
  select jsonb_agg(jsonb_build_object(
    'status', evento.status, 'observacao', evento.observacao, 'data', evento.created_at
  ) order by evento.created_at desc, evento.id desc) itens
  from public.sugestoes_melhoria_status_historico evento
  where evento.sugestao_id = sugestao.id
) historico on true
left join lateral (
  select
    array_agg(plano.id order by plano.created_at desc, plano.id desc) ids,
    jsonb_agg(jsonb_build_object(
      'id', plano.id, 'setor', plano.setor, 'acao', plano.o_que,
      'status', plano.status, 'prazo', plano.quando
    ) order by plano.created_at desc, plano.id desc) itens
  from public.planos_acao_5w2h plano
  where plano.sugestao_id = sugestao.id
) acoes on true;

grant select on public.sugestoes_melhoria_publicas to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Laminacao: subsetores Roda, Laminacao e Bobinador
-- ---------------------------------------------------------------------------

alter table public.subordinacoes add column if not exists subsetor text;
alter table public.matriz_flexibilidade_atividades add column if not exists subsetor text;
alter table public.auditorias add column if not exists subsetor text;

update public.subordinacoes
set subsetor = 'laminacao'
where lower(setor) = 'laminacao' and subsetor is null;

update public.matriz_flexibilidade_atividades
set subsetor = 'laminacao'
where lower(setor) = 'laminacao' and subsetor is null;

update public.auditorias auditoria
set subsetor = coalesce((
  select colaborador.subsetor
  from public.subordinacoes colaborador
  where colaborador.ativo
    and lower(colaborador.setor) = 'laminacao'
    and lower(btrim(colaborador.subordinado)) = lower(btrim(auditoria.team))
  order by colaborador.updated_at desc, colaborador.id desc
  limit 1
), 'laminacao')
where auditoria.type = 'laminacao' and auditoria.subsetor is null;

alter table public.subordinacoes drop constraint if exists subordinacoes_subsetor_check;
alter table public.subordinacoes add constraint subordinacoes_subsetor_check check (
  (lower(setor) = 'laminacao' and (subsetor is null or subsetor in ('roda','laminacao','bobinador')))
  or (lower(setor) <> 'laminacao' and subsetor is null)
);

alter table public.matriz_flexibilidade_atividades drop constraint if exists matriz_flex_subsetor_check;
alter table public.matriz_flexibilidade_atividades add constraint matriz_flex_subsetor_check check (
  (lower(setor) = 'laminacao' and subsetor in ('roda','laminacao','bobinador'))
  or (lower(setor) <> 'laminacao' and subsetor is null)
);

alter table public.auditorias drop constraint if exists auditorias_subsetor_check;
alter table public.auditorias add constraint auditorias_subsetor_check check (
  (type = 'laminacao' and (subsetor is null or subsetor in ('roda','laminacao','bobinador')))
  or (type <> 'laminacao' and subsetor is null)
);

drop index if exists public.matriz_flex_atividade_setor_nome_ativo_idx;
create unique index matriz_flex_atividade_setor_subsetor_nome_ativo_idx
  on public.matriz_flexibilidade_atividades (
    lower(setor), coalesce(subsetor, ''), lower(nome)
  ) where ativo;

drop index if exists public.matriz_flex_atividade_setor_ordem_idx;
create index matriz_flex_atividade_setor_subsetor_ordem_idx
  on public.matriz_flexibilidade_atividades (setor, subsetor, ordem)
  where ativo;

insert into public.matriz_flexibilidade_atividades (setor, subsetor, ordem, nome)
values
  ('laminacao','roda',10,'Acionar a bomba de água da roda, identificar ar e executar a retirada do ar'),
  ('laminacao','roda',20,'Localizar e ligar o acetileno da roda e da fita'),
  ('laminacao','roda',30,'Instalar e conferir o alinhamento do batoque da panela'),
  ('laminacao','roda',40,'Regular e conferir a tocha de aquecimento do bico'),
  ('laminacao','roda',50,'Identificar a função da solenoide e do compressor do sistema de ar'),
  ('laminacao','roda',60,'Inspecionar e garantir a eficiência dos bicos aspersores de água'),
  ('laminacao','roda',70,'Acionar e verificar o pistão da fita pela manivela e volante'),
  ('laminacao','roda',80,'Manusear a roda tensora com macaco hidráulico'),
  ('laminacao','roda',90,'Consultar a temperatura da água da roda no sensor e display'),
  ('laminacao','roda',100,'Posicionar e ligar o aftercooler'),
  ('laminacao','roda',110,'Realizar a passagem de vareta no bico da panela'),
  ('laminacao','roda',120,'Posicionar e regular o maçarico de aquecimento do bico'),
  ('laminacao','roda',130,'Ligar e regular a tocha da fita'),
  ('laminacao','roda',140,'Tapar o dreno da panela'),
  ('laminacao','roda',150,'Ligar ou desligar a torre de resfriamento para manter a água entre 28 e 30 graus'),
  ('laminacao','bobinador',10,'Conferir o painel de acionamento do bobinador'),
  ('laminacao','bobinador',20,'Conferir o óleo da roldana'),
  ('laminacao','bobinador',30,'Abrir os dois registros de ar do cano proveniente da decapagem'),
  ('laminacao','bobinador',40,'Verificar se o purgador aplica cera no vergalhão'),
  ('laminacao','bobinador',50,'Configurar abertura e fechamento da amarração do vergalhão'),
  ('laminacao','bobinador',60,'Configurar o automático da amarração e avaliar a quantidade de voltas'),
  ('laminacao','bobinador',70,'Executar a transposição de gaiolas'),
  ('laminacao','bobinador',80,'Retirar amostras conforme o padrão'),
  ('laminacao','bobinador',90,'Inspecionar defeitos, causas e ações aplicáveis ao vergalhão'),
  ('laminacao','bobinador',100,'Preencher o formulário de defeitos na folha de processo'),
  ('laminacao','bobinador',110,'Executar limpeza e organização e preencher o formulário'),
  ('laminacao','bobinador',120,'Comunicar-se com o laboratório conforme o fluxo'),
  ('laminacao','bobinador',130,'Operar a prensa do jumbo'),
  ('laminacao','bobinador',140,'Embalar o jumbo com plástico'),
  ('laminacao','bobinador',150,'Passar a cinta e colocar o grampo'),
  ('laminacao','bobinador',160,'Prensar com a bobina pneumática'),
  ('laminacao','bobinador',170,'Pesar e emitir etiqueta com peso total e líquido'),
  ('laminacao','bobinador',180,'Registrar o peso no caderno ou folha de processo'),
  ('laminacao','bobinador',190,'Trocar as cintas ao final do rolo'),
  ('laminacao','bobinador',200,'Pesar o palete antes do setup e avaliar sua condição')
on conflict do nothing;

create or replace function public.save_subordinacao_v2(
  p_password text,
  p_id bigint,
  p_setor text,
  p_subsetor text,
  p_supervisor text,
  p_subordinado text,
  p_cargo text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_setor text := lower(btrim(coalesce(p_setor, '')));
  v_subsetor text := nullif(lower(btrim(coalesce(p_subsetor, ''))), '');
begin
  if v_setor = 'laminacao' and v_subsetor not in ('roda','laminacao','bobinador') then
    raise exception 'Selecione Roda, Laminacao ou Bobinador';
  end if;
  if v_setor <> 'laminacao' then
    v_subsetor := null;
  end if;
  v_id := public.save_subordinacao(
    p_password, p_id, v_setor, p_supervisor, p_subordinado, p_cargo
  );
  update public.subordinacoes
  set subsetor = v_subsetor, updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

revoke all on function public.save_subordinacao_v2(text,bigint,text,text,text,text,text) from public;
grant execute on function public.save_subordinacao_v2(text,bigint,text,text,text,text,text) to anon, authenticated;

create or replace function public.save_matriz_flexibilidade_atividade_v2(
  p_password text,
  p_id bigint,
  p_setor text,
  p_subsetor text,
  p_nome text,
  p_ordem integer
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_setor text := lower(btrim(coalesce(p_setor, '')));
  v_subsetor text := nullif(lower(btrim(coalesce(p_subsetor, ''))), '');
  v_nome text := btrim(coalesce(p_nome, ''));
  v_ordem integer := greatest(coalesce(p_ordem, 10), 1);
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa invalida';
  end if;
  if v_setor = '' or v_nome = '' then
    raise exception 'Setor e atividade sao obrigatorios';
  end if;
  if v_setor = 'laminacao' and v_subsetor not in ('roda','laminacao','bobinador') then
    raise exception 'Selecione o subsetor da Laminacao';
  end if;
  if v_setor <> 'laminacao' then
    v_subsetor := null;
  end if;
  if p_id is null then
    insert into public.matriz_flexibilidade_atividades (setor, subsetor, ordem, nome)
    values (v_setor, v_subsetor, v_ordem, v_nome)
    returning id into v_id;
  else
    update public.matriz_flexibilidade_atividades
    set setor = v_setor, subsetor = v_subsetor, ordem = v_ordem,
        nome = v_nome, ativo = true, updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then
      raise exception 'Atividade da matriz nao encontrada';
    end if;
  end if;
  return v_id;
end;
$$;

revoke all on function public.save_matriz_flexibilidade_atividade_v2(text,bigint,text,text,text,integer) from public;
grant execute on function public.save_matriz_flexibilidade_atividade_v2(text,bigint,text,text,text,integer) to anon, authenticated;

drop function if exists public.get_matriz_flexibilidade_publica();
drop function if exists public.get_subordinacoes_publicas();

create function public.get_subordinacoes_publicas()
returns table(
  id bigint,
  setor text,
  supervisor text,
  subordinado text,
  cargo text,
  subsetor text
)
language sql
security definer
set search_path = ''
as $$
  select s.id, s.setor, s.supervisor, s.subordinado, s.cargo, s.subsetor
  from public.subordinacoes s
  where s.ativo
  order by s.setor, s.subsetor nulls first, s.supervisor nulls first, s.subordinado;
$$;

revoke all on function public.get_subordinacoes_publicas() from public;
grant execute on function public.get_subordinacoes_publicas() to anon, authenticated;

create function public.get_matriz_flexibilidade_publica()
returns table(
  atividade_id bigint,
  setor text,
  atividade_ordem integer,
  atividade_nome text,
  subordinacao_id bigint,
  supervisor text,
  subordinado text,
  cargo text,
  nivel smallint,
  avaliado_em date,
  updated_at timestamptz,
  atividade_subsetor text,
  subordinacao_subsetor text
)
language sql
stable
set search_path = ''
as $$
  select
    atividade.id,
    atividade.setor,
    atividade.ordem,
    atividade.nome,
    subordinacao.id,
    subordinacao.supervisor,
    subordinacao.subordinado,
    subordinacao.cargo,
    nivel.nivel,
    nivel.avaliado_em,
    nivel.updated_at,
    atividade.subsetor,
    subordinacao.subsetor
  from public.matriz_flexibilidade_atividades atividade
  left join public.get_subordinacoes_publicas() subordinacao
    on lower(subordinacao.setor) = lower(atividade.setor)
   and (
     lower(atividade.setor) <> 'laminacao'
     or subordinacao.subsetor = atividade.subsetor
   )
  left join public.matriz_flexibilidade_niveis nivel
    on nivel.atividade_id = atividade.id
   and nivel.subordinacao_id = subordinacao.id
  where atividade.ativo
  order by atividade.setor, atividade.subsetor nulls first, atividade.ordem, atividade.id,
           subordinacao.supervisor nulls first, subordinacao.subordinado nulls first;
$$;

revoke all on function public.get_matriz_flexibilidade_publica() from public;
grant execute on function public.get_matriz_flexibilidade_publica() to anon, authenticated;

create or replace function public.save_auditoria_contextual_v2(
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
  p_audited_role text,
  p_subsetor text
) returns boolean
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
  v_subsetor text := nullif(lower(btrim(coalesce(p_subsetor, ''))), '');
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha invalida';
  end if;
  if v_role not in ('supervisor', 'subordinado') then
    raise exception 'Tipo de auditado invalido';
  end if;
  if v_setor = '' or v_nome = '' then
    raise exception 'Setor e colaborador sao obrigatorios';
  end if;

  if v_role = 'supervisor' then
    select lider.nome into v_nome
    from public.liderancas lider
    where lider.ativo and lider.cargo = 'Supervisor'
      and lower(btrim(lider.setor)) = v_setor
      and lower(btrim(lider.nome)) = lower(v_nome)
    limit 1;
    if v_nome is null then
      raise exception 'Supervisor nao cadastrado na lideranca deste setor';
    end if;
    v_supervisor := v_nome;
    if v_setor <> 'laminacao' then v_subsetor := null; end if;
  else
    select cadastro.subordinado, cadastro.supervisor, cadastro.cargo, cadastro.subsetor
    into v_nome, v_supervisor, v_cargo, v_subsetor
    from public.subordinacoes cadastro
    where cadastro.ativo
      and lower(btrim(cadastro.setor)) = v_setor
      and lower(btrim(cadastro.subordinado)) = lower(v_nome)
    limit 1;
    if v_nome is null then
      raise exception 'Colaborador operacional nao cadastrado neste setor';
    end if;
    if v_setor = 'laminacao' and v_subsetor not in ('roda','laminacao','bobinador') then
      raise exception 'Cadastre o subsetor do colaborador antes da auditoria';
    end if;
  end if;

  insert into public.auditorias (
    audit_id, type, team, audit_date, cargo, score, total_ok, total_no, report,
    supervisor_name, audited_role, subsetor
  ) values (
    p_audit_id, p_type, v_nome, p_audit_date, v_cargo, p_score, p_total_ok, p_total_no,
    coalesce(p_report, '{}'::jsonb), v_supervisor, v_role, v_subsetor
  )
  on conflict (audit_id) do update set
    type = excluded.type, team = excluded.team, audit_date = excluded.audit_date,
    cargo = excluded.cargo, score = excluded.score, total_ok = excluded.total_ok,
    total_no = excluded.total_no, report = excluded.report,
    supervisor_name = excluded.supervisor_name, audited_role = excluded.audited_role,
    subsetor = excluded.subsetor;
  return true;
end;
$$;

revoke all on function public.save_auditoria_contextual_v2(
  text,bigint,text,text,date,text,numeric,integer,integer,jsonb,text,text,text
) from public;
grant execute on function public.save_auditoria_contextual_v2(
  text,bigint,text,text,date,text,numeric,integer,integer,jsonb,text,text,text
) to anon, authenticated;

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
    raise exception 'Dados da auditoria nao informados';
  end if;
  v_payload := p_payload::jsonb;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'Formato da auditoria invalido';
  end if;
  return public.save_auditoria_contextual_v2(
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
    v_payload->>'p_audited_role',
    coalesce(v_payload->>'p_subsetor', v_payload->'p_report'->>'subsetor')
  );
end;
$$;

create or replace view public.auditoria_resultados as
select
  audit_id, created_at, type, team, audit_date, cargo, score, total_ok, total_no,
  supervisor_name, audited_role, subsetor
from public.auditorias;

grant select on public.auditoria_resultados to anon, authenticated;
