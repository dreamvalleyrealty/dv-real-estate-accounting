-- Permit the separate audit event used when a landlord is handed a printed statement.
ALTER TABLE public.dv_accounting_email_log
  DROP CONSTRAINT IF EXISTS dv_accounting_email_log_document_type_check;

ALTER TABLE public.dv_accounting_email_log
  ADD CONSTRAINT dv_accounting_email_log_document_type_check
  CHECK (document_type = ANY (ARRAY[
    'COMMISSION_INVOICE',
    'SELLER_COMMISSION_STATEMENT',
    'LAWYER_DOCUMENT_PACKAGE',
    'DEPOSIT_RECEIPT',
    'SELLER_COMMISSION_STATEMENT_HARDCOPY'
  ]::text[]));
