-- 0055: persist commission payment method and payment reference for cheque/EFT stubs.
ALTER TABLE public.dv_accounting_commission_cheques
  ADD COLUMN IF NOT EXISTS payment_method text NOT NULL DEFAULT 'CHEQUE',
  ADD COLUMN IF NOT EXISTS payment_reference text;

UPDATE public.dv_accounting_commission_cheques
SET payment_method = COALESCE(NULLIF(payment_method,''),'CHEQUE')
WHERE payment_method IS NULL OR payment_method = '';

ALTER TABLE public.dv_accounting_commission_cheques
  DROP CONSTRAINT IF EXISTS dv_accounting_commission_cheques_payment_method_check;

ALTER TABLE public.dv_accounting_commission_cheques
  ADD CONSTRAINT dv_accounting_commission_cheques_payment_method_check
  CHECK (payment_method IN ('CHEQUE','EFT'));
