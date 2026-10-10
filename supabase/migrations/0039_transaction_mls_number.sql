-- 0039: MLS number for transactions
ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS mls_number text;
CREATE INDEX IF NOT EXISTS idx_dv_accounting_transactions_mls_number
  ON public.dv_accounting_transactions(mls_number);
NOTIFY pgrst, 'reload schema';
