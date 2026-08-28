-- A restrição UNIQUE (setor, ordem) já mantém o índice necessário para leitura ordenada.
drop index if exists public.formularios_auditoria_itens_setor_ordem_idx;
