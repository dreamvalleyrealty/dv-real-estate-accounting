-- Secure trust-account information sharing.
-- Full bank instructions are encrypted by the Edge Function before storage.
-- Never add a public/authenticated SELECT policy to the instruction table.

create table if not exists public.dv_accounting_trust_account_instructions (
  account_type text primary key check (account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
  institution text not null,
  transit_number text not null,
  account_number_ciphertext bytea not null,
  account_name text not null,
  bank_address text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
alter table public.dv_accounting_trust_account_instructions enable row level security;
revoke all on public.dv_accounting_trust_account_instructions from anon, authenticated;
grant all on public.dv_accounting_trust_account_instructions to service_role;

create table if not exists public.dv_accounting_trust_info_email_log (
  id uuid primary key default gen_random_uuid(),
  recipient_name text not null,
  recipient_email text not null,
  account_types text[] not null check (
    cardinality(account_types) between 1 and 2
    and account_types <@ array['REAL_ESTATE_TRUST','COMMISSION_TRUST']::text[]
  ),
  sent_by uuid not null references auth.users(id),
  sent_by_email text,
  status text not null default 'PENDING' check (
    status in ('PENDING','SENT','FAILED','VERIFIED','VIEWED','EXPIRED','REVOKED')
  ),
  token_hash text not null unique,
  otp_hash text,
  otp_expires_at timestamptz,
  otp_attempts integer not null default 0,
  link_expires_at timestamptz not null,
  verified_at timestamptz,
  opened_at timestamptz,
  token_verified boolean not null default false,
  otp_sent_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error_message text,
  provider_message_id text
);
create index if not exists dv_accounting_trust_info_email_log_expiry_idx
 on public.dv_accounting_trust_info_email_log(link_expires_at);
create index if not exists dv_accounting_trust_info_email_log_sender_idx
 on public.dv_accounting_trust_info_email_log(sent_by,created_at desc);
alter table public.dv_accounting_trust_info_email_log enable row level security;
revoke all on public.dv_accounting_trust_info_email_log from anon, authenticated;
grant all on public.dv_accounting_trust_info_email_log to service_role;
-- The audit history is returned only by a service-role Edge Function after role checks.
