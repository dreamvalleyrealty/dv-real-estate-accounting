-- Fix: the trade-review RPC expects a dedicated listing_id field on submissions.
-- Keep historical listing references from payload and allow future writes to populate the column.
ALTER TABLE public.dv_accounting_agent_trade_submissions
  ADD COLUMN IF NOT EXISTS listing_id uuid;

UPDATE public.dv_accounting_agent_trade_submissions
SET listing_id = NULLIF(payload->>'listing_id', '')::uuid
WHERE listing_id IS NULL
  AND COALESCE(payload->>'listing_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

CREATE INDEX IF NOT EXISTS dv_accounting_agent_trade_submissions_listing_id_idx
  ON public.dv_accounting_agent_trade_submissions (listing_id)
  WHERE listing_id IS NOT NULL;
