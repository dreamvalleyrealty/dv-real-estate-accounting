-- Seller-side trust settlement workflow for DV Real Estate Accounting.
-- This migration records the required settlement checkpoints. Bank transactions must still
-- be posted by the application using the existing bank-transaction workflow.

create table if not exists public.dv_accounting_seller_settlements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  transaction_id uuid not null,
  status text not null default 'DEPOSIT_HELD'
    check (status in (
      'DEPOSIT_HELD',
      'SELLER_PROCEEDS_CALCULATED',
      'SELLER_PAID',
      'COMMISSION_TRANSFERRED',
      'READY_FOR_COMMISSION_PAYROLL',
      'COMMISSION_PAYROLL_PROCESSED',
      'PAYMENTS_COMPLETED'
    )),
  deposit_held_amount numeric(14,2) not null default 0 check (deposit_held_amount >= 0),
  seller_proceeds_amount numeric(14,2) not null default 0 check (seller_proceeds_amount >= 0),
  listing_commission_amount numeric(14,2) not null default 0 check (listing_commission_amount >= 0),
  cooperating_commission_amount numeric(14,2) not null default 0 check (cooperating_commission_amount >= 0),
  commission_hst_amount numeric(14,2) not null default 0 check (commission_hst_amount >= 0),
  seller_paid_amount numeric(14,2) not null default 0 check (seller_paid_amount >= 0),
  seller_payment_reference text,
  seller_payment_date date,
  real_estate_trust_account_id uuid,
  commission_trust_account_id uuid,
  commission_transfer_amount numeric(14,2) not null default 0 check (commission_transfer_amount >= 0),
  commission_transfer_reference text,
  commission_transfer_date date,
  commission_payroll_id uuid,
  listing_agent_paid_amount numeric(14,2) not null default 0 check (listing_agent_paid_amount >= 0),
  cooperating_brokerage_paid_amount numeric(14,2) not null default 0 check (cooperating_brokerage_paid_amount >= 0),
  payments_completed_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid,
  unique (company_id, transaction_id)
);

create index if not exists dv_accounting_seller_settlements_status_idx
  on public.dv_accounting_seller_settlements (company_id, status);

create or replace function public.dv_accounting_validate_seller_settlement()
returns trigger
language plpgsql
as $$
declare
  v_commission_total numeric(14,2);
begin
  new.updated_at := now();
  v_commission_total := round(
    coalesce(new.listing_commission_amount, 0)
    + coalesce(new.cooperating_commission_amount, 0)
    + coalesce(new.commission_hst_amount, 0), 2
  );

  if new.status in ('SELLER_PAID','COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL',
                    'COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    if new.seller_paid_amount < new.seller_proceeds_amount then
      raise exception 'Seller must be paid in full before this settlement can advance.';
    end if;
    if coalesce(nullif(trim(new.seller_payment_reference), ''), '') = ''
       or new.seller_payment_date is null then
      raise exception 'Record the seller payment reference and date before advancing.';
    end if;
  end if;

  if new.status in ('COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL',
                    'COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    if new.commission_transfer_amount <> v_commission_total then
      raise exception 'Commission trust transfer must equal listing commission plus cooperating commission plus HST.';
    end if;
    if coalesce(nullif(trim(new.commission_transfer_reference), ''), '') = ''
       or new.commission_transfer_date is null then
      raise exception 'Record the commission trust transfer reference and date before advancing.';
    end if;
    if new.real_estate_trust_account_id is null
       or new.commission_trust_account_id is null
       or new.real_estate_trust_account_id = new.commission_trust_account_id then
      raise exception 'Select two different trust accounts for the commission transfer.';
    end if;
  end if;

  if new.status in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED')
     and new.seller_paid_amount < new.seller_proceeds_amount then
    raise exception 'Commission Payroll is blocked until the seller is fully paid.';
  end if;

  if new.status = 'PAYMENTS_COMPLETED' then
    if new.listing_agent_paid_amount + new.cooperating_brokerage_paid_amount > new.commission_transfer_amount then
      raise exception 'Recorded commission payments cannot exceed the transferred commission funds.';
    end if;
    new.payments_completed_at := coalesce(new.payments_completed_at, now());
  end if;

  return new;
end;
$$;

drop trigger if exists dv_accounting_seller_settlement_validate
  on public.dv_accounting_seller_settlements;
create trigger dv_accounting_seller_settlement_validate
before insert or update on public.dv_accounting_seller_settlements
for each row execute function public.dv_accounting_validate_seller_settlement();

alter table public.dv_accounting_seller_settlements enable row level security;

-- Access follows the app's existing authenticated-user model. Role/tenant restrictions
-- should be tightened to match the project's established company-scope policies.
drop policy if exists "Authenticated users can read seller settlements"
  on public.dv_accounting_seller_settlements;
create policy "Authenticated users can read seller settlements"
  on public.dv_accounting_seller_settlements
  for select to authenticated using (true);

drop policy if exists "Authenticated users can insert seller settlements"
  on public.dv_accounting_seller_settlements;
create policy "Authenticated users can insert seller settlements"
  on public.dv_accounting_seller_settlements
  for insert to authenticated with check (true);

drop policy if exists "Authenticated users can update seller settlements"
  on public.dv_accounting_seller_settlements;
create policy "Authenticated users can update seller settlements"
  on public.dv_accounting_seller_settlements
  for update to authenticated using (true) with check (true);
