-- 0020: promotion flag and fee type validation
alter table public.dv_accounting_agent_fee_rules
  add column if not exists is_promotion boolean not null default false;

alter table public.dv_accounting_fee_plans
  drop constraint if exists dv_accounting_fee_plans_admin_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_lease_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_commercial_lease_type_check;

alter table public.dv_accounting_fee_plans
  add constraint dv_accounting_fee_plans_admin_fee_buy_sell_type_check check(admin_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_lease_type_check check(admin_fee_lease_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check check(admin_fee_commercial_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_commercial_lease_type_check check(admin_fee_commercial_lease_type in ('AMOUNT','PERCENT'));

alter table public.dv_accounting_agent_fee_rules
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_lease_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_commercial_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_commercial_lease_type_check;

alter table public.dv_accounting_agent_fee_rules
  add constraint dv_accounting_agent_fee_rules_admin_fee_buy_sell_type_check check(admin_fee_buy_sell_type is null or admin_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_lease_type_check check(admin_fee_lease_type is null or admin_fee_lease_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_commercial_buy_sell_type_check check(admin_fee_commercial_buy_sell_type is null or admin_fee_commercial_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_commercial_lease_type_check check(admin_fee_commercial_lease_type is null or admin_fee_commercial_lease_type in ('AMOUNT','PERCENT'));
