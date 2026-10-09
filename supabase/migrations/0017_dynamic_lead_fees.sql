-- Dynamic lead fees by transaction type: Buy/Sell vs Lease
alter table public.dv_accounting_fee_plans
  add column if not exists lead_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists lead_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists lead_fee_lease_type text not null default 'AMOUNT',
  add column if not exists lead_fee_lease_value numeric(14,4) not null default 0;

alter table public.dv_accounting_fee_plans
  drop constraint if exists dv_accounting_fee_plans_lead_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_lead_fee_lease_type_check;

alter table public.dv_accounting_fee_plans
  add constraint dv_accounting_fee_plans_lead_fee_buy_sell_type_check
    check (lead_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_lead_fee_lease_type_check
    check (lead_fee_lease_type in ('AMOUNT','PERCENT'));

alter table public.dv_accounting_agent_fee_settings
  add column if not exists lead_fee_buy_sell_type text,
  add column if not exists lead_fee_buy_sell_value numeric(14,4),
  add column if not exists lead_fee_lease_type text,
  add column if not exists lead_fee_lease_value numeric(14,4);

alter table public.dv_accounting_agent_fee_settings
  drop constraint if exists dv_accounting_agent_fee_settings_lead_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_settings_lead_fee_lease_type_check;

alter table public.dv_accounting_agent_fee_settings
  add constraint dv_accounting_agent_fee_settings_lead_fee_buy_sell_type_check
    check (lead_fee_buy_sell_type is null or lead_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_settings_lead_fee_lease_type_check
    check (lead_fee_lease_type is null or lead_fee_lease_type in ('AMOUNT','PERCENT'));
