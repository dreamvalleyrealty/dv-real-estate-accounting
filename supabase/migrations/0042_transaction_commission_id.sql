-- 0042_transaction_commission_id.sql
-- Repair the transaction-to-commission link used by the close workflow.
-- The close RPC stores the generated commission record ID on the transaction.

ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS commission_id uuid;

CREATE INDEX IF NOT EXISTS idx_dv_accounting_transactions_commission_id
  ON public.dv_accounting_transactions(commission_id);

-- Backfill the link for transactions that already have a legacy commission row.
UPDATE public.dv_accounting_transactions t
SET commission_id = c.id
FROM public.dv_accounting_commissions c
WHERE c.transaction_id = t.id
  AND t.commission_id IS NULL;

NOTIFY pgrst, 'reload schema';
