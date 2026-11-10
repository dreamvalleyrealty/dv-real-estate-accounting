-- Existing status indexes already cover these list filters.
DROP INDEX IF EXISTS public.idx_dv_accounting_agent_trade_submissions_status_list;
DROP INDEX IF EXISTS public.idx_dv_accounting_listing_submissions_status_list;
