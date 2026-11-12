-- Stage listing expense reimbursements for explicit admin review.
-- This migration creates no trust disbursements, bank movements, or GL entries.
-- Reimbursement posting must be implemented as a separate atomic RPC after review.

create table if not exists public.dv_accounting_listing_expense_reviews (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  transaction_id uuid not null,
  settlement_id uuid not null references public.dv_accounting_seller_settlements(id) on delete restrict,
  listing_expense_id uuid not null references public.dv_listing_expenses(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  operating_payment_date date,
  operating_payment_reference text,
  operating_payment_proof_path text,
  status text not null default 'DRAFT'
    check (status in ('DRAFT','APPROVED','REJECTED','REIMBURSED')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text,
  reimbursement_trust_transaction_id uuid,
  reimbursement_reference text,
  reimbursement_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (listing_expense_id)
);

create index if not exists dv_accounting_listing_expense_reviews_settlement_idx
  on public.dv_accounting_listing_expense_reviews(settlement_id,status);

create or replace function public.dv_accounting_validate_listing_expense_review()
returns trigger language plpgsql set search_path=public as $$
declare
  v_settlement public.dv_accounting_seller_settlements%rowtype;
  v_expense record;
begin
  select * into v_settlement
  from public.dv_accounting_seller_settlements
  where id=new.settlement_id;
  if not found or v_settlement.company_id<>new.company_id
     or v_settlement.transaction_id<>new.transaction_id then
    raise exception 'Listing expense review must match the selected settlement and company.';
  end if;
  select listing_id, line_total into v_expense
  from public.dv_listing_expenses where id=new.listing_expense_id;
  if not found or v_expense.listing_id is distinct from
    (select listing_id from public.dv_accounting_transactions where id=new.transaction_id) then
    raise exception 'Expense does not belong to the settlement listing.';
  end if;
  if new.amount <> round(coalesce(v_expense.line_total,0),2) then
    raise exception 'Expense amount must match the current listing expense amount.';
  end if;
  if tg_op='UPDATE' and old.status='REIMBURSED' and new is distinct from old then
    raise exception 'Reimbursed expense records are locked; use an authorized correction process.';
  end if;
  if tg_op='UPDATE' and old.status='APPROVED'
     and (new.amount is distinct from old.amount
       or new.listing_expense_id is distinct from old.listing_expense_id
       or new.operating_payment_reference is distinct from old.operating_payment_reference
       or new.operating_payment_date is distinct from old.operating_payment_date) then
    raise exception 'Approved expense details cannot be edited; reject and create a corrected review.';
  end if;
  if new.status in ('APPROVED','REIMBURSED') then
    if new.operating_payment_date is null
       or nullif(trim(coalesce(new.operating_payment_reference,'')),'') is null
       or nullif(trim(coalesce(new.operating_payment_proof_path,'')),'') is null then
      raise exception 'Operating payment date, reference and proof are required before approval.';
    end if;
    if new.reviewed_by is null or new.reviewed_at is null then
      raise exception 'Reviewer and review timestamp are required.';
    end if;
  end if;
  if new.status='REIMBURSED' then
    if new.reimbursement_trust_transaction_id is null
       or new.reimbursement_date is null
       or nullif(trim(coalesce(new.reimbursement_reference,'')),'') is null then
      raise exception 'Posted trust transaction, reimbursement date and reference are required.';
    end if;
  elsif new.reimbursement_trust_transaction_id is not null then
    raise exception 'A trust reimbursement reference may only be recorded after posting.';
  end if;
  new.updated_at:=now();
  return new;
end $$;

drop trigger if exists dv_accounting_listing_expense_review_validate
  on public.dv_accounting_listing_expense_reviews;
create trigger dv_accounting_listing_expense_review_validate
before insert or update on public.dv_accounting_listing_expense_reviews
for each row execute function public.dv_accounting_validate_listing_expense_review();

alter table public.dv_accounting_listing_expense_reviews enable row level security;

-- Read access is restricted to administrators. Posting access is intentionally
-- not granted: approvals and reimbursements require a separate audited RPC.
drop policy if exists "Admin reads listing expense reviews"
  on public.dv_accounting_listing_expense_reviews;
create policy "Admin reads listing expense reviews"
  on public.dv_accounting_listing_expense_reviews
  for select to authenticated
  using (upper(coalesce(auth.jwt()->'app_metadata'->>'role',
                        auth.jwt()->'user_metadata'->>'role',''))
         in ('SUPERADMIN','ADMIN'));

comment on table public.dv_accounting_listing_expense_reviews is
  'Audit staging for operating-paid listing expenses. Does not itself authorize or post trust disbursements.';
