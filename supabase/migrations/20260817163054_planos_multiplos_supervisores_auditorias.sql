create table if not exists public.planos_acao_supervisores (
  plano_id bigint not null references public.planos_acao_5w2h(id) on delete cascade,
  supervisor text not null,
  created_at timestamptz not null default now(),
  constraint planos_acao_supervisores_pkey primary key (plano_id, supervisor),
  constraint planos_acao_supervisores_nome_not_blank check (btrim(supervisor) <> '')
);

create unique index if not exists planos_acao_supervisores_nome_normalizado_uidx
  on public.planos_acao_supervisores (plano_id, lower(btrim(supervisor)));

create index if not exists planos_acao_supervisores_busca_idx
  on public.planos_acao_supervisores (lower(btrim(supervisor)), plano_id);

create table if not exists public.planos_acao_auditorias (
  plano_id bigint not null references public.planos_acao_5w2h(id) on delete cascade,
  auditoria_id bigint not null references public.auditorias(audit_id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint planos_acao_auditorias_pkey primary key (plano_id, auditoria_id)
);

create index if not exists planos_acao_auditorias_auditoria_idx
  on public.planos_acao_auditorias (auditoria_id, plano_id);

alter table public.planos_acao_supervisores enable row level security;
alter table public.planos_acao_auditorias enable row level security;

revoke all on table public.planos_acao_supervisores from anon, authenticated;
revoke all on table public.planos_acao_auditorias from anon, authenticated;
grant all on table public.planos_acao_supervisores to service_role;
grant all on table public.planos_acao_auditorias to service_role;

-- Preserva o vínculo único das ações antigas quando a auditoria ainda existe.
insert into public.planos_acao_auditorias (plano_id, auditoria_id)
select plano.id, plano.auditoria_id
from public.planos_acao_5w2h plano
join public.auditorias auditoria on auditoria.audit_id = plano.auditoria_id
where plano.auditoria_id is not null
on conflict (plano_id, auditoria_id) do nothing;

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
  coalesce(auditorias.itens, '[]'::jsonb) as auditorias
from public.planos_acao_5w2h plano
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
  join public.auditorias auditoria on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.plano_id = plano.id
) auditorias on true;

revoke all on table public.planos_acao_publicos from public;
grant select on table public.planos_acao_publicos to anon, authenticated, service_role;

create or replace function public.save_plano_acao_5w2h_v2(
  p_password text,
  p_id bigint,
  p_setor text,
  p_supervisores text[],
  p_auditoria_ids bigint[],
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
set search_path = public, extensions
as $$
declare
  v_setor text := btrim(coalesce(p_setor, ''));
  v_auditoria_ids bigint[];
  v_primeira_auditoria bigint;
  v_auditoria_origem text;
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
    id, setor, auditoria_id, auditoria_origem, o_que, por_que, onde,
    quando, quem, como, quanto, status, updated_at
  ) values (
    p_id, v_setor, v_primeira_auditoria, v_auditoria_origem,
    btrim(p_o_que), nullif(btrim(p_por_que), ''), nullif(btrim(p_onde), ''),
    p_quando, nullif(btrim(p_quem), ''), nullif(btrim(p_como), ''),
    nullif(btrim(p_quanto), ''), coalesce(nullif(btrim(p_status), ''), 'Pendente'), now()
  )
  on conflict (id) do update set
    setor = excluded.setor,
    auditoria_id = excluded.auditoria_id,
    auditoria_origem = excluded.auditoria_origem,
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

  return p_id;
end;
$$;

revoke execute on function public.save_plano_acao_5w2h_v2(
  text, bigint, text, text[], bigint[], text, text, text, date, text, text, text, text
) from public;
grant execute on function public.save_plano_acao_5w2h_v2(
  text, bigint, text, text[], bigint[], text, text, text, date, text, text, text, text
) to anon, authenticated, service_role;
