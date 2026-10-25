-- Draft transaction creation/synchronization is called explicitly from trade form save flows.
-- This avoids transaction-editor payload updates being mistaken for agent-side trade edits.
DROP TRIGGER IF EXISTS trg_auto_create_trade_submission_transaction ON public.dv_accounting_agent_trade_submissions;
DROP TRIGGER IF EXISTS trg_sync_trade_submission_draft_transaction ON public.dv_accounting_agent_trade_submissions;
DROP FUNCTION IF EXISTS public.dv_accounting_sync_submission_to_draft_transaction();
