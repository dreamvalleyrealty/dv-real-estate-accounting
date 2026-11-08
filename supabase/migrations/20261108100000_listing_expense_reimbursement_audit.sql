-- Track whether listing expenses were paid by the brokerage operating account
-- and whether the corresponding trust reimbursement has already been posted.
-- This migration does not post or alter any trust or general-ledger transactions.

alter table public.dv_listing_expenses
  add column if not exists operating_paid_confirmed boolean not null default false,
  add column if not exists operating_payment_date date,
  add column if not exists operating_payment_reference text,
  add column if not exists operating_payment_notes text,
  add column if not exists reimbursement_status text not null default 'NOT_REIMBURSED',
  add column if not exists reimbursement_trust_transaction_id uuid,
  add column if not exists reimbursed_at timestamptz,
  add column if not exists reimbursed_by uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'dv_listing_expenses_reimbursement_status_check'
      and conrelid = 'public.dv_listing_expenses'::regclass
  ) then
    alter table public.dv_listing_expenses
      add constraint dv_listing_expenses_reimbursement_status_check
      check (reimbursement_status in ('NOT_REIMBURSED','PENDING','COMPLETED'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'dv_listing_expenses_reimbursement_posting_unique'
      and conrelid = 'public.dv_listing_expenses'::regclass
  ) then
    alter table public.dv_listing_expenses
      add constraint dv_listing_expenses_reimbursement_posting_unique
      unique (reimbursement_trust_transaction_id);
  end if;
end $$;

create index if not exists dv_listing_expenses_reimbursement_status_idx
  on public.dv_listing_expenses (listing_id, reimbursement_status);

comment on column public.dv_listing_expenses.operating_paid_confirmed is
  'Admin confirmation that this listing expense was actually paid from the brokerage operating account.';
comment on column public.dv_listing_expenses.reimbursement_status is
  'Trust reimbursement lifecycle; COMPLETED means a corresponding trust transaction has been posted.';
