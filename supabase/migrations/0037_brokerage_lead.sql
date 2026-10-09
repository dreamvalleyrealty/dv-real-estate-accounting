-- 0037: brokerage lead tracking for transactions
ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS is_brokerage_lead boolean NOT NULL DEFAULT false;

ALTER TABLE public.dv_accounting_transaction_agent_info
  ADD COLUMN IF NOT EXISTS lead_fee_applies boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_dv_accounting_transactions_brokerage_lead
  ON public.dv_accounting_transactions(is_brokerage_lead);

NOTIFY pgrst, 'reload schema';
