ALTER TABLE public.dv_accounting_agent_trade_documents
  ADD COLUMN IF NOT EXISTS match_notes text NOT NULL DEFAULT '';
