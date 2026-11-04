-- Consolidated document review notifications for Listings and Trades.
alter table public.dv_accounting_listing_documents
  add column if not exists review_notes text;

create table if not exists public.dv_accounting_document_review_cycles (
  id uuid primary key default gen_random_uuid(),
  submission_type text not null check (submission_type in ('LISTING','TRADE')),
  submission_id uuid not null,
  cycle_number integer not null check (cycle_number > 0),
  outcome text not null check (outcome in ('ALL_APPROVED','ACTION_REQUIRED','PARTIALLY_APPROVED')),
  document_snapshot jsonb not null default '[]'::jsonb,
  total_documents integer not null default 0,
  approved_count integer not null default 0,
  not_approved_count integer not null default 0,
  email_status text not null default 'PENDING' check (email_status in ('PENDING','SENDING','SENT','FAILED','SKIPPED')),
  email_provider_id text,
  email_error text,
  email_sent_at timestamptz,
  sms_status text not null default 'PENDING' check (sms_status in ('PENDING','SENDING','SENT','FAILED','SKIPPED')),
  sms_provider_id text,
  sms_error text,
  sms_sent_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (submission_type, submission_id, cycle_number)
);

alter table public.dv_accounting_document_review_cycles enable row level security;
drop policy if exists "document review cycles admin read" on public.dv_accounting_document_review_cycles;
create policy "document review cycles admin read"
on public.dv_accounting_document_review_cycles for select to authenticated
using (exists (
  select 1 from public.dv_accounting_user_profiles p
  where p.user_id = (select auth.uid()) and p.active = true
    and upper(p.role) in ('ADMIN','SUPERADMIN','MANAGER')
));
revoke all on public.dv_accounting_document_review_cycles from anon, authenticated;
grant select on public.dv_accounting_document_review_cycles to authenticated;
