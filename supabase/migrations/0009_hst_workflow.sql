create table if not exists public.dv_accounting_hst_adjustments(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 hst_period_id uuid references public.dv_accounting_hst_periods(id) on delete cascade,
 adjustment_date date not null default current_date,
 amount numeric(14,2) not null default 0,
 reason text not null,
 created_at timestamptz not null default now()
);
alter table public.dv_accounting_hst_periods add column if not exists filing_due_date date;
alter table public.dv_accounting_hst_periods add column if not exists filed_at timestamptz;
alter table public.dv_accounting_hst_periods add column if not exists paid_at timestamptz;
alter table public.dv_accounting_hst_periods add column if not exists payment_amount numeric(14,2);
alter table public.dv_accounting_hst_periods add column if not exists confirmation_number text;
alter table public.dv_accounting_hst_periods add column if not exists reviewed_at timestamptz;
alter table public.dv_accounting_hst_adjustments enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_hst_adjustments;
create policy "authenticated access" on public.dv_accounting_hst_adjustments for all to authenticated using(true) with check(true);
