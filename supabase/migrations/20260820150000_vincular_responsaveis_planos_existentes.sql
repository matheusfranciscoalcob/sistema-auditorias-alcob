-- Vincula os nomes já digitados no campo Quem aos cadastros ativos.
-- O texto histórico é preservado; a nova tabela passa a ser a fonte estruturada.
insert into public.planos_acao_responsaveis (
  plano_id, origem, origem_id, nome, cargo, setor
)
select
  plano.id,
  pessoa.origem,
  pessoa.origem_id,
  pessoa.nome,
  pessoa.cargo,
  pessoa.setor
from public.planos_acao_5w2h plano
cross join lateral (
  select 'lideranca'::text origem, lider.id origem_id, lider.nome, lider.cargo, lider.setor
  from public.liderancas lider
  where lider.ativo
  union all
  select 'operacional'::text, colaborador.id, colaborador.subordinado, colaborador.cargo, colaborador.setor
  from public.subordinacoes colaborador
  where colaborador.ativo
) pessoa
where nullif(btrim(plano.quem), '') is not null
  and (
    translate(lower(plano.quem), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')
      like '%' || translate(lower(pessoa.nome), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') || '%'
    or (
      lower(pessoa.nome) = 'daiane'
      and lower(plano.quem) like '%dayane%'
    )
  )
on conflict do nothing;
