-- Square checkout for agent invoices. Apply only after invoice register migration 202611150001.
alter table public.dv_agent_invoice_payments
  add column if not exists square_payment_id text;
create unique index if not exists uq_dv_agent_invoice_payments_square_payment
  on public.dv_agent_invoice_payments(square_payment_id) where square_payment_id is not null;

create table if not exists public.dv_agent_invoice_square_sessions (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.dv_agent_invoices(id) on delete restrict,
  agent_id uuid not null references public.dv_accounting_agents(id) on delete restrict,
  square_order_id text not null unique,
  square_payment_link_id text,
  checkout_url text not null,
  amount_cents bigint not null check (amount_cents > 0),
  currency text not null default 'CAD' check (currency='CAD'),
  status text not null default 'PENDING' check (status in ('PENDING','PAID','EXPIRED','FAILED')),
  square_payment_id text unique,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists idx_dv_agent_invoice_square_sessions_invoice
  on public.dv_agent_invoice_square_sessions(invoice_id,created_at desc);
alter table public.dv_agent_invoice_square_sessions enable row level security;
revoke all on public.dv_agent_invoice_square_sessions from anon,authenticated;
