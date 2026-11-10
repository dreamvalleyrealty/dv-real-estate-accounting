-- Add targeted indexes for the Transactions, Listings, and Trade Submissions
-- list queries. Check column existence so older deployments with schema drift
-- do not fail the entire migration.
DO $$
DECLARE
  item record;
  index_name text;
BEGIN
  FOR item IN
    SELECT * FROM (VALUES
      ('dv_accounting_transactions','transaction_date'),
      ('dv_accounting_transactions','status'),
      ('dv_accounting_transactions','listing_id'),
      ('dv_accounting_transactions','agent_id'),
      ('dv_accounting_transactions','created_at'),
      ('dv_accounting_listing_submissions','status'),
      ('dv_accounting_listing_submissions','agent_id'),
      ('dv_accounting_listing_submissions','created_at'),
      ('dv_accounting_agent_trade_submissions','status'),
      ('dv_accounting_agent_trade_submissions','agent_id'),
      ('dv_accounting_agent_trade_submissions','transaction_id'),
      ('dv_accounting_agent_trade_submissions','created_at'),
      ('dv_accounting_agent_trade_submissions','updated_at'),
      ('dv_accounting_agent_trade_documents','submission_id'),
      ('dv_accounting_listing_documents','listing_id')
    ) AS candidates(table_name, column_name)
  LOOP
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = item.table_name
        AND c.column_name = item.column_name
    ) THEN
      index_name := 'idx_' || item.table_name || '_' || item.column_name || '_list';
      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON public.%I (%I)',
        index_name, item.table_name, item.column_name
      );
    END IF;
  END LOOP;
END $$;
