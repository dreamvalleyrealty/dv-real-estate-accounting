-- Link every invoice email attempt to its agent invoice for a durable send history.
alter table public.dv_accounting_email_log
  add column if not exists agent_invoice_id uuid
  references public.dv_agent_invoices(id) on delete set null;

create index if not exists idx_dv_accounting_email_log_agent_invoice
  on public.dv_accounting_email_log(agent_invoice_id, created_at desc)
  where agent_invoice_id is not null;
