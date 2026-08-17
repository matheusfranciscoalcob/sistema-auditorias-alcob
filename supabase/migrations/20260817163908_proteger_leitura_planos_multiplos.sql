create policy "Planos de ação são públicos para leitura"
  on public.planos_acao_5w2h
  for select
  to anon, authenticated
  using (true);

create policy "Supervisores vinculados são públicos para leitura"
  on public.planos_acao_supervisores
  for select
  to anon, authenticated
  using (true);

create policy "Auditorias vinculadas são públicas para leitura"
  on public.planos_acao_auditorias
  for select
  to anon, authenticated
  using (true);

grant select on table public.planos_acao_5w2h to anon, authenticated;
grant select on table public.planos_acao_supervisores to anon, authenticated;
grant select on table public.planos_acao_auditorias to anon, authenticated;

alter view public.planos_acao_publicos set (security_invoker = true);
