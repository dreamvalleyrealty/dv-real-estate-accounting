-- Allow audited delivery of pre-construction builder invoices.
-- Keep every document type already permitted by the current email-log constraint.
alter table public.dv_accounting_email_log
  drop constraint if exists dv_accounting_email_log_document_type_check;

alter table public.dv_accounting_email_log
  add constraint dv_accounting_email_log_document_type_check
  check (document_type = any (array[
    'COMMISSION_INVOICE',
    'PRECONSTRUCTION_BUILDER_INVOICE',
    'SELLER_COMMISSION_STATEMENT',
    'LAWYER_DOCUMENT_PACKAGE',
    'DEPOSIT_RECEIPT',
    'SELLER_COMMISSION_STATEMENT_HARDCOPY',
    'AGENT_INVOICE'
  ]::text[]));
