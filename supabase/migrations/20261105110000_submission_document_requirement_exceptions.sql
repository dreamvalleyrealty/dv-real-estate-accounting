-- Submission-specific document requirement exceptions.
-- An administrator may waive a single uploaded document requirement with an auditable reason.

alter table public.dv_accounting_listing_documents
  add column if not exists requirement_waived boolean not null default false,
  add column if not exists waiver_reason text,
  add column if not exists waived_by uuid references auth.users(id) on delete set null,
  add column if not exists waived_at timestamptz;

alter table public.dv_accounting_agent_trade_documents
  add column if not exists requirement_waived boolean not null default false,
  add column if not exists waiver_reason text,
  add column if not exists waived_by uuid references auth.users(id) on delete set null,
  add column if not exists waived_at timestamptz;

alter table public.dv_accounting_listing_documents
  drop constraint if exists listing_document_waiver_reason_check;
alter table public.dv_accounting_listing_documents
  add constraint listing_document_waiver_reason_check
  check (
    (requirement_waived = false and waiver_reason is null and waived_by is null and waived_at is null)
    or
    (requirement_waived = true and length(trim(coalesce(waiver_reason,''))) >= 10 and waived_by is not null and waived_at is not null)
  );

alter table public.dv_accounting_agent_trade_documents
  drop constraint if exists trade_document_waiver_reason_check;
alter table public.dv_accounting_agent_trade_documents
  add constraint trade_document_waiver_reason_check
  check (
    (requirement_waived = false and waiver_reason is null and waived_by is null and waived_at is null)
    or
    (requirement_waived = true and length(trim(coalesce(waiver_reason,''))) >= 10 and waived_by is not null and waived_at is not null)
  );

create table if not exists public.dv_accounting_document_requirement_exceptions (
  id uuid primary key default gen_random_uuid(),
  submission_type text not null check (submission_type in ('LISTING','TRADE')),
  submission_id uuid not null,
  document_type text not null,
  reason text not null check (length(trim(reason)) >= 10),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (submission_type, submission_id, document_type)
);
alter table public.dv_accounting_document_requirement_exceptions enable row level security;
revoke all on public.dv_accounting_document_requirement_exceptions from anon;
grant select, insert, update, delete on public.dv_accounting_document_requirement_exceptions to authenticated;
drop policy if exists "document exceptions admin manage" on public.dv_accounting_document_requirement_exceptions;
create policy "document exceptions admin manage"
on public.dv_accounting_document_requirement_exceptions
for all to authenticated
using (
  (submission_type='LISTING' and public.dv_accounting_is_listing_admin())
  or (submission_type='TRADE' and public.dv_accounting_is_trade_submission_admin())
)
with check (
  (submission_type='LISTING' and public.dv_accounting_is_listing_admin())
  or (submission_type='TRADE' and public.dv_accounting_is_trade_submission_admin())
);
drop policy if exists "document exceptions agent read own" on public.dv_accounting_document_requirement_exceptions;
create policy "document exceptions agent read own"
on public.dv_accounting_document_requirement_exceptions
for select to authenticated
using (
 (submission_type='LISTING' and exists (
   select 1 from public.dv_accounting_listing_submissions s
   join public.dv_accounting_agents a on a.id=s.agent_id
   where s.id=submission_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))
 ))
 or
 (submission_type='TRADE' and exists (
   select 1 from public.dv_accounting_agent_trade_submissions s
   where s.id=submission_id and (s.submitted_by=auth.uid() or s.agent_id=public.dv_accounting_my_agent_id())
 ))
);
