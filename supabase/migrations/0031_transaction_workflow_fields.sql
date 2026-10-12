-- 0031_transaction_workflow_fields.sql
-- Adds the transaction fields used by the six-tab transaction workflow.
alter table public.dv_accounting_transactions
  add column if not exists listing_id uuid references public.dv_accounting_listings(id),
  add column if not exists is_own_listing boolean not null default false,
  add column if not exists street_number text,
  add column if not exists street_name text,
  add column if not exists unit_number text,
  add column if not exists city text,
  add column if not exists province text default 'ON',
  add column if not exists postal_code text,
  add column if not exists offer_date date,
  add column if not exists firm_date date,
  add column if not exists close_date date,
  add column if not exists entry_date date,
  add column if not exists mls_number text,
  add column if not exists transaction_type text default 'BUY_SELL',
  add column if not exists market_segment text default 'RESIDENTIAL',
  add column if not exists is_brokerage_lead boolean not null default false,
  add column if not exists agent_id uuid references public.dv_accounting_agents(id),
  add column if not exists trust_bank_account_id uuid references public.dv_accounting_bank_accounts(id),
  add column if not exists commission_approved boolean not null default false,
  add column if not exists commission_approved_at timestamptz,
  add column if not exists commission_approved_amount numeric(14,2) not null default 0,
  add column if not exists commission_approved_agent_payable numeric(14,2) not null default 0,
  add column if not exists commission_payroll_status text not null default 'NOT_READY';
alter table public.dv_accounting_transactions alter column commission_payroll_status set default 'NOT_READY';

create index if not exists idx_dv_accounting_tx_listing on public.dv_accounting_transactions(listing_id);
create index if not exists idx_dv_accounting_tx_agent on public.dv_accounting_transactions(agent_id);
create index if not exists idx_dv_accounting_tx_close_date on public.dv_accounting_transactions(close_date);

-- Keep transaction date aligned for older records where Entry Date is available.
update public.dv_accounting_transactions
set entry_date = coalesce(entry_date, transaction_date)
where entry_date is null;
