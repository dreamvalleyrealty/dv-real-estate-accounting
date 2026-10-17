-- Store the uploaded supporting receipt, cheque image, or bank draft with the trust deposit.
alter table public.dv_accounting_transaction_trust
  add column if not exists receipt_attachment_path text;

alter table public.dv_accounting_transaction_trust
  add column if not exists receipt_attachment_name text;

alter table public.dv_accounting_transaction_trust
  add column if not exists receipt_attachment_mime_type text;
