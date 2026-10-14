-- Persist trade submission document ordering for drag-and-drop in agent and admin portals.
ALTER TABLE public.dv_accounting_agent_trade_documents
  ADD COLUMN IF NOT EXISTS sort_order integer;

WITH ranked AS (
  SELECT id, row_number() OVER (PARTITION BY submission_id ORDER BY created_at ASC, id ASC) AS position
  FROM public.dv_accounting_agent_trade_documents
)
UPDATE public.dv_accounting_agent_trade_documents AS docs
SET sort_order = ranked.position
FROM ranked
WHERE docs.id = ranked.id AND docs.sort_order IS NULL;

CREATE INDEX IF NOT EXISTS dv_accounting_agent_trade_documents_submission_sort_idx
  ON public.dv_accounting_agent_trade_documents (submission_id, sort_order, created_at);
