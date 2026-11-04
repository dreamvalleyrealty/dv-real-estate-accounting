
-- Separate audit log for listing-specific Real Estate Trust deposit instructions.
-- It intentionally stores no banking numbers or recipient verification secrets in plaintext.
create table if not exists public.dv_accounting_deposit_instruction_email_log (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.dv_accounting_listing_submissions(id),
  property_address text not null,
  recipient_name text not null,
  recipient_email text not null,
  sent_by uuid not null references auth.users(id),
  sent_by_email text,
  status text not null default 'PENDING' check (status in ('PENDING','SENT','FAILED','VERIFIED','VIEWED','EXPIRED','REVOKED')),
  token_hash text not null unique,
  otp_hash text,
  otp_expires_at timestamptz,
  otp_sent_at timestamptz,
  otp_attempts integer not null default 0,
  token_verified boolean not null default false,
  link_expires_at timestamptz not null,
  verified_at timestamptz,
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error_message text,
  provider_message_id text
);
create index if not exists dv_accounting_deposit_instruction_log_expiry_idx
  on public.dv_accounting_deposit_instruction_email_log(link_expires_at);
create index if not exists dv_accounting_deposit_instruction_log_sender_idx
  on public.dv_accounting_deposit_instruction_email_log(sent_by,created_at desc);
create index if not exists dv_accounting_deposit_instruction_log_listing_idx
  on public.dv_accounting_deposit_instruction_email_log(listing_id,created_at desc);
alter table public.dv_accounting_deposit_instruction_email_log enable row level security;
revoke all on public.dv_accounting_deposit_instruction_email_log from anon,authenticated;
grant all on public.dv_accounting_deposit_instruction_email_log to service_role;
