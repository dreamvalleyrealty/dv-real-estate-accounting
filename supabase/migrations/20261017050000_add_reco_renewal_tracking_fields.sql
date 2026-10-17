alter table public.dv_accounting_agents
  add column if not exists reco_renewal_status text not null default 'NONE',
  add column if not exists reco_renewal_applied_date date,
  add column if not exists reco_eligible_to_trade boolean not null default false;
alter table public.dv_accounting_agents
  drop constraint if exists dv_accounting_agents_reco_renewal_status_check;
alter table public.dv_accounting_agents
  add constraint dv_accounting_agents_reco_renewal_status_check
  check (reco_renewal_status in ('NONE','IN_PROGRESS'));
