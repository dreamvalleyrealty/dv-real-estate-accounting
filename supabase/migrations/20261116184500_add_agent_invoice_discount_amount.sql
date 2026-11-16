alter table public.dv_agent_invoices add column if not exists discount_amount numeric(12,2) not null default 0;
