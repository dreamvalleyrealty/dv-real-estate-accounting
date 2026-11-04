-- Deposit proof uploads received through the one-week link in deposit-instruction emails.
create table if not exists public.dv_accounting_deposit_receipt_uploads (
  id uuid primary key default gen_random_uuid(),
  email_log_id uuid not null references public.dv_accounting_deposit_instruction_email_log(id) on delete cascade,
  listing_id uuid not null references public.dv_accounting_listing_submissions(id) on delete cascade,
  property_address text not null,
  recipient_email text not null,
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null,
  file_size bigint not null check (file_size > 0),
  uploaded_at timestamptz not null default now()
);
create index if not exists dv_accounting_deposit_receipt_uploads_listing_idx
  on public.dv_accounting_deposit_receipt_uploads(listing_id, uploaded_at desc);
create index if not exists dv_accounting_deposit_receipt_uploads_email_idx
  on public.dv_accounting_deposit_receipt_uploads(email_log_id, uploaded_at desc);
alter table public.dv_accounting_deposit_receipt_uploads enable row level security;
revoke all on public.dv_accounting_deposit_receipt_uploads from anon, authenticated;
grant all on public.dv_accounting_deposit_receipt_uploads to service_role;
