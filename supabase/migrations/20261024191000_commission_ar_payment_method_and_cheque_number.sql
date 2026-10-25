ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS ar_payment_method text,
  ADD COLUMN IF NOT EXISTS ar_payment_cheque_number text;

ALTER TABLE public.dv_accounting_transactions
  DROP CONSTRAINT IF EXISTS dv_accounting_transactions_ar_payment_method_check;
ALTER TABLE public.dv_accounting_transactions
  ADD CONSTRAINT dv_accounting_transactions_ar_payment_method_check
  CHECK (ar_payment_method IS NULL OR ar_payment_method IN ('EFT','CHEQUE'));

COMMENT ON COLUMN public.dv_accounting_transactions.ar_payment_method IS 'Method used to receive commission A/R: EFT or CHEQUE.';
COMMENT ON COLUMN public.dv_accounting_transactions.ar_payment_cheque_number IS 'Cheque number when commission A/R is received by cheque.';
