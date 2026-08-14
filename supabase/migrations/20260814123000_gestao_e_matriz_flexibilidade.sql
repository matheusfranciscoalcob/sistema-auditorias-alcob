create table if not exists public.matriz_flexibilidade_atividades (
  id bigint generated always as identity primary key,
  setor text not null,
  ordem integer not null default 10,
  nome text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint matriz_flex_atividade_setor_not_blank check (btrim(setor) <> ''),
  constraint matriz_flex_atividade_nome_not_blank check (btrim(nome) <> ''),
  constraint matriz_flex_atividade_ordem_positive check (ordem > 0)
);

create unique index if not exists matriz_flex_atividade_setor_nome_ativo_idx
  on public.matriz_flexibilidade_atividades (lower(setor), lower(nome))
  where ativo;

create index if not exists matriz_flex_atividade_setor_ordem_idx
  on public.matriz_flexibilidade_atividades (setor, ordem)
  where ativo;

create table if not exists public.matriz_flexibilidade_niveis (
  id bigint generated always as identity primary key,
  subordinacao_id bigint not null references public.subordinacoes(id),
  atividade_id bigint not null references public.matriz_flexibilidade_atividades(id),
  nivel smallint not null,
  avaliado_em date not null default current_date,
  updated_at timestamptz not null default now(),
  constraint matriz_flex_nivel_range check (nivel between 0 and 4),
  constraint matriz_flex_nivel_unique unique (subordinacao_id, atividade_id)
);

create index if not exists matriz_flex_nivel_atividade_idx
  on public.matriz_flexibilidade_niveis (atividade_id, subordinacao_id);

alter table public.matriz_flexibilidade_atividades enable row level security;
alter table public.matriz_flexibilidade_niveis enable row level security;

revoke all on table public.matriz_flexibilidade_atividades from anon, authenticated;
revoke all on table public.matriz_flexibilidade_niveis from anon, authenticated;
grant select on table public.matriz_flexibilidade_atividades to anon, authenticated;
grant select on table public.matriz_flexibilidade_niveis to anon, authenticated;
grant select, insert, update, delete on table public.matriz_flexibilidade_atividades to service_role;
grant select, insert, update, delete on table public.matriz_flexibilidade_niveis to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'matriz_flexibilidade_atividades'
      and policyname = 'Matriz de atividades visível publicamente'
  ) then
    create policy "Matriz de atividades visível publicamente"
      on public.matriz_flexibilidade_atividades
      for select to anon, authenticated
      using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'matriz_flexibilidade_niveis'
      and policyname = 'Níveis da matriz visíveis publicamente'
  ) then
    create policy "Níveis da matriz visíveis publicamente"
      on public.matriz_flexibilidade_niveis
      for select to anon, authenticated
      using (true);
  end if;
end $$;

insert into public.matriz_flexibilidade_atividades (setor, ordem, nome)
select seed.setor, seed.ordem, seed.nome
from (values
  ('laminacao', 10, 'Preenchimento de checklist'),
  ('laminacao', 20, 'Ajuste do endireitador'),
  ('laminacao', 30, 'Ajuste do rebarbador e faca'),
  ('laminacao', 40, 'Ligar e desligar motores'),
  ('laminacao', 50, 'Passagem de barra para aquecimento'),
  ('laminacao', 60, 'Retirar ar do sistema'),
  ('laminacao', 70, 'Ajuste de velocidade'),
  ('laminacao', 80, 'Ajuste dos cilindros'),
  ('laminacao', 90, 'Passagem de barra'),
  ('laminacao', 100, 'Controle térmico'),
  ('laminacao', 110, 'Retirada de amostras'),
  ('laminacao', 120, 'Ações em falhas de produção'),
  ('laminacao', 130, 'Limpezas'),
  ('laminacao', 140, 'Manutenções de produção'),
  ('laminacao', 150, 'Auxílio mecânico'),
  ('laminacao', 160, 'Preenchimento de relatórios')
) as seed(setor, ordem, nome)
where not exists (
  select 1
  from public.matriz_flexibilidade_atividades current_activity
  where current_activity.ativo
    and lower(current_activity.setor) = lower(seed.setor)
    and lower(current_activity.nome) = lower(seed.nome)
);

create or replace function public.get_matriz_flexibilidade_publica()
returns table (
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
  updated_at timestamptz
)
language sql
stable
security invoker
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
    nivel.updated_at
  from public.matriz_flexibilidade_atividades atividade
  left join public.get_subordinacoes_publicas() subordinacao
    on lower(subordinacao.setor) = lower(atividade.setor)
  left join public.matriz_flexibilidade_niveis nivel
    on nivel.atividade_id = atividade.id
   and nivel.subordinacao_id = subordinacao.id
  where atividade.ativo
  order by atividade.setor, atividade.ordem, atividade.id,
           subordinacao.supervisor nulls first, subordinacao.subordinado nulls first;
$$;

revoke execute on function public.get_matriz_flexibilidade_publica() from public;
grant execute on function public.get_matriz_flexibilidade_publica() to anon, authenticated, service_role;

create or replace function public.save_matriz_flexibilidade_atividade(
  p_password text,
  p_id bigint,
  p_setor text,
  p_nome text,
  p_ordem integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_setor text := btrim(coalesce(p_setor, ''));
  v_nome text := btrim(coalesce(p_nome, ''));
  v_ordem integer := greatest(coalesce(p_ordem, 10), 1);
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;
  if v_setor = '' or v_nome = '' then
    raise exception 'Setor e atividade são obrigatórios';
  end if;

  if p_id is null then
    insert into public.matriz_flexibilidade_atividades (setor, ordem, nome)
    values (v_setor, v_ordem, v_nome)
    returning id into v_id;
  else
    update public.matriz_flexibilidade_atividades
    set setor = v_setor,
        ordem = v_ordem,
        nome = v_nome,
        ativo = true,
        updated_at = now()
    where id = p_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Atividade da matriz não encontrada';
    end if;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_matriz_flexibilidade_atividade(text, bigint, text, text, integer) from public;
grant execute on function public.save_matriz_flexibilidade_atividade(text, bigint, text, text, integer) to anon, authenticated, service_role;

create or replace function public.delete_matriz_flexibilidade_atividade(
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
    raise exception 'Senha administrativa inválida';
  end if;

  update public.matriz_flexibilidade_atividades
  set ativo = false, updated_at = now()
  where id = p_id and ativo;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

revoke execute on function public.delete_matriz_flexibilidade_atividade(text, bigint) from public;
grant execute on function public.delete_matriz_flexibilidade_atividade(text, bigint) to anon, authenticated, service_role;

create or replace function public.save_matriz_flexibilidade_nivel(
  p_password text,
  p_subordinacao_id bigint,
  p_atividade_id bigint,
  p_nivel integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;
  if p_subordinacao_id is null or p_atividade_id is null then
    raise exception 'Subordinado e atividade são obrigatórios';
  end if;
  if p_nivel is not null and (p_nivel < 0 or p_nivel > 4) then
    raise exception 'O nível deve estar entre 0 e 4';
  end if;
  if not exists (
    select 1
    from public.subordinacoes subordinacao
    join public.matriz_flexibilidade_atividades atividade
      on atividade.id = p_atividade_id
     and atividade.ativo
     and lower(atividade.setor) = lower(subordinacao.setor)
    where subordinacao.id = p_subordinacao_id
      and subordinacao.ativo
  ) then
    raise exception 'A atividade não pertence ao setor deste subordinado';
  end if;

  if p_nivel is null then
    delete from public.matriz_flexibilidade_niveis
    where subordinacao_id = p_subordinacao_id
      and atividade_id = p_atividade_id;
    return true;
  end if;

  insert into public.matriz_flexibilidade_niveis (
    subordinacao_id, atividade_id, nivel, avaliado_em, updated_at
  ) values (
    p_subordinacao_id, p_atividade_id, p_nivel::smallint, current_date, now()
  )
  on conflict (subordinacao_id, atividade_id) do update set
    nivel = excluded.nivel,
    avaliado_em = excluded.avaliado_em,
    updated_at = excluded.updated_at;

  return true;
end;
$$;

revoke execute on function public.save_matriz_flexibilidade_nivel(text, bigint, bigint, integer) from public;
grant execute on function public.save_matriz_flexibilidade_nivel(text, bigint, bigint, integer) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
