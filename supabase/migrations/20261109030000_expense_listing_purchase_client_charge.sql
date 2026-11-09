-- Link operating expenses to a listing or purchase and record whether the cost is recoverable from the client.
alter table public.dv_accounting_expenses
  add column if not exists related_record_type text not null default 'NONE',
  add column if not exists related_listing_id uuid references public.dv_accounting_listing_submissions(id) on delete set null,
  add column if not exists related_transaction_id uuid references public.dv_accounting_transactions(id) on delete set null,
  add column if not exists charge_to_client boolean not null default false;

alter table public.dv_accounting_expenses
  drop constraint if exists dv_accounting_expenses_related_record_type_check,
  add constraint dv_accounting_expenses_related_record_type_check
    check (related_record_type in ('NONE','LISTING','PURCHASE'));

alter table public.dv_accounting_expenses
  drop constraint if exists dv_accounting_expenses_related_record_check,
  add constraint dv_accounting_expenses_related_record_check
    check (
      (related_record_type = 'NONE' and related_listing_id is null and related_transaction_id is null and charge_to_client = false)
      or
      (related_record_type = 'LISTING' and related_listing_id is not null and related_transaction_id is null)
      or
      (related_record_type = 'PURCHASE' and related_transaction_id is not null and related_listing_id is null)
    );

create index if not exists dv_accounting_expenses_related_listing_idx
  on public.dv_accounting_expenses (related_listing_id)
  where related_listing_id is not null;

create index if not exists dv_accounting_expenses_related_purchase_idx
  on public.dv_accounting_expenses (related_transaction_id)
  where related_transaction_id is not null;

create index if not exists dv_accounting_expenses_client_charge_idx
  on public.dv_accounting_expenses (company_id, charge_to_client, expense_date)
  where charge_to_client = true;

comment on column public.dv_accounting_expenses.related_record_type is
  'Whether this expense belongs to a listing, a purchase transaction, or general brokerage operations.';
comment on column public.dv_accounting_expenses.charge_to_client is
  'Marks an expense as recoverable from the client. This flag does not automatically invoice or collect the amount.';
