create table if not exists public.dv_agent_invoice_payment_links (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.dv_agent_invoices(id) on delete cascade,
 token_hash text not null unique,
 created_by uuid,
 expires_at timestamptz not null default (now() + interval '90 days'),
 revoked_at timestamptz,
 created_at timestamptz not null default now()
);
create index if not exists dv_agent_invoice_payment_links_invoice_idx on public.dv_agent_invoice_payment_links(invoice_id);
alter table public.dv_agent_invoice_payment_links enable row level security;
revoke all on public.dv_agent_invoice_payment_links from anon, authenticated;
create table if not exists public.dv_agent_invoice_payment_submissions (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.dv_agent_invoices(id) on delete cascade,
 agent_id uuid,
 amount numeric(12,2) not null check (amount > 0),
 payment_method text not null check (payment_method in ('E-transfer')),
 reference_number text not null,
 submitted_at timestamptz not null default now(),
 status text not null default 'PENDING' check (status in ('PENDING','CONFIRMED','REJECTED')),
 reviewed_by uuid,
 reviewed_at timestamptz,
 admin_note text,
 created_at timestamptz not null default now()
);
create index if not exists dv_agent_invoice_payment_submissions_invoice_idx on public.dv_agent_invoice_payment_submissions(invoice_id,submitted_at desc);
alter table public.dv_agent_invoice_payment_submissions enable row level security;
revoke all on public.dv_agent_invoice_payment_submissions from anon, authenticated;