-- 0031: complete transaction agent linkage
-- Adds the deal agent foreign key used by the six-tab transaction workflow.

ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS agent_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'dv_accounting_transactions_agent_id_fkey'
  ) THEN
    ALTER TABLE public.dv_accounting_transactions
      ADD CONSTRAINT dv_accounting_transactions_agent_id_fkey
      FOREIGN KEY (agent_id)
      REFERENCES public.dv_accounting_agents(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_dv_accounting_transactions_agent_id
  ON public.dv_accounting_transactions(agent_id);
