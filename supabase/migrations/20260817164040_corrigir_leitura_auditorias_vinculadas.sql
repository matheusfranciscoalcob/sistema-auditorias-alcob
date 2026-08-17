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
  join public.auditoria_resultados auditoria on auditoria.audit_id = vinculo.auditoria_id
  where vinculo.plano_id = plano.id
) auditorias on true;

revoke all on table public.planos_acao_publicos from public;
grant select on table public.planos_acao_publicos to anon, authenticated, service_role;
