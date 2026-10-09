-- 0036: transaction conditions / file requirements due-for tracking
ALTER TABLE public.dv_accounting_transaction_conditions
  ADD COLUMN IF NOT EXISTS due_for text DEFAULT 'BOTH';

UPDATE public.dv_accounting_transaction_conditions
SET due_for='BOTH'
WHERE due_for IS NULL OR btrim(due_for)='';

ALTER TABLE public.dv_accounting_transaction_conditions
  ALTER COLUMN due_for SET DEFAULT 'BOTH';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='dv_accounting_transaction_conditions_due_for_chk'
      AND conrelid='public.dv_accounting_transaction_conditions'::regclass
  ) THEN
    ALTER TABLE public.dv_accounting_transaction_conditions
      ADD CONSTRAINT dv_accounting_transaction_conditions_due_for_chk
      CHECK (due_for IN ('BUYER','SELLER','BOTH','BROKERAGE'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_dv_accounting_tx_conditions_due
  ON public.dv_accounting_transaction_conditions(transaction_id, due_for);
NOTIFY pgrst, 'reload schema';
