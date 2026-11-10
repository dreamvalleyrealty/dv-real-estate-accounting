-- Remove newly added list indexes where equivalent indexes already existed.
DROP INDEX IF EXISTS public.idx_dv_accounting_agent_trade_documents_submission_id_list;
DROP INDEX IF EXISTS public.idx_dv_accounting_transactions_agent_id_list;
DROP INDEX IF EXISTS public.idx_dv_accounting_transactions_listing_id_list;
DROP INDEX IF EXISTS public.idx_dv_accounting_transactions_transaction_date_list;
