create table if not exists public.formularios_auditoria_itens (
  id bigint generated always as identity primary key,
  setor text not null check (btrim(setor) <> ''),
  item_key text not null check (item_key ~ '^[A-Za-z0-9_-]{1,100}$'),
  grupo text not null check (btrim(grupo) <> '' and char_length(grupo) <= 120),
  pergunta text not null check (btrim(pergunta) <> '' and char_length(pergunta) <= 1000),
  peso numeric(10, 3) not null check (peso > 0 and peso <= 1000),
  parametro text not null default '' check (char_length(parametro) <= 2000),
  ordem integer not null check (ordem > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint formularios_auditoria_itens_setor_item_key_key unique (setor, item_key),
  constraint formularios_auditoria_itens_setor_ordem_key unique (setor, ordem)
);

alter table public.formularios_auditoria_itens enable row level security;
revoke all on table public.formularios_auditoria_itens from public, anon, authenticated;
revoke all on sequence public.formularios_auditoria_itens_id_seq from public, anon, authenticated;

create or replace function public.get_formularios_auditoria()
returns table (
  setor text,
  item_key text,
  grupo text,
  pergunta text,
  peso numeric,
  parametro text,
  ordem integer,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select f.setor, f.item_key, f.grupo, f.pergunta, f.peso,
         f.parametro, f.ordem, f.updated_at
  from public.formularios_auditoria_itens f
  order by f.setor, f.ordem;
$$;

create or replace function public.save_formulario_auditoria(
  p_password text,
  p_setor text,
  p_items jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_setor text := btrim(coalesce(p_setor, ''));
  v_item jsonb;
  v_count integer := 0;
  v_key text;
  v_group text;
  v_question text;
  v_parameter text;
  v_weight numeric;
begin
  if not public.admin_password_ok(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if v_setor = '' or char_length(v_setor) > 80 then
    raise exception 'Setor inválido';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 200 then
    raise exception 'O formulário deve possuir de 1 a 200 perguntas';
  end if;

  delete from public.formularios_auditoria_itens where setor = v_setor;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_count := v_count + 1;
    v_key := btrim(coalesce(v_item->>'item_key', ''));
    v_group := btrim(coalesce(v_item->>'grupo', ''));
    v_question := btrim(coalesce(v_item->>'pergunta', ''));
    v_parameter := btrim(coalesce(v_item->>'parametro', ''));

    begin
      v_weight := (v_item->>'peso')::numeric;
    exception when others then
      raise exception 'Peso inválido na pergunta %', v_count;
    end;

    if v_key !~ '^[A-Za-z0-9_-]{1,100}$' then
      raise exception 'Identificador inválido na pergunta %', v_count;
    end if;
    if v_group = '' or char_length(v_group) > 120 then
      raise exception 'Grupo inválido na pergunta %', v_count;
    end if;
    if v_question = '' or char_length(v_question) > 1000 then
      raise exception 'Texto inválido na pergunta %', v_count;
    end if;
    if char_length(v_parameter) > 2000 then
      raise exception 'Parâmetro muito longo na pergunta %', v_count;
    end if;
    if v_weight is null or v_weight <= 0 or v_weight > 1000 then
      raise exception 'O peso da pergunta % deve ser maior que zero', v_count;
    end if;

    insert into public.formularios_auditoria_itens
      (setor, item_key, grupo, pergunta, peso, parametro, ordem)
    values
      (v_setor, v_key, v_group, v_question, v_weight, v_parameter, v_count);
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.get_formularios_auditoria() from public;
revoke execute on function public.get_formularios_auditoria() from authenticated;
grant execute on function public.get_formularios_auditoria() to anon;

revoke execute on function public.save_formulario_auditoria(text, text, jsonb) from public;
revoke execute on function public.save_formulario_auditoria(text, text, jsonb) from authenticated;
grant execute on function public.save_formulario_auditoria(text, text, jsonb) to anon;

comment on table public.formularios_auditoria_itens is
  'Perguntas e pesos personalizados por formulário de auditoria. A ausência de linhas mantém o modelo padrão do site.';
