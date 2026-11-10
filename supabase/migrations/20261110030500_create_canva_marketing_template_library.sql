create table if not exists public.dv_accounting_canva_templates (
  canva_template_id text primary key,
  title text not null,
  view_url text,
  create_url text,
  category text not null default 'Uncategorized',
  is_active boolean not null default true,
  sort_order integer not null default 0,
  can_autofill boolean not null default false,
  dataset jsonb not null default '{}'::jsonb,
  canva_created_at bigint,
  canva_updated_at bigint,
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.dv_accounting_canva_templates enable row level security;

drop policy if exists "Active Canva templates visible to signed-in users" on public.dv_accounting_canva_templates;
create policy "Active Canva templates visible to signed-in users"
on public.dv_accounting_canva_templates for select
to authenticated
using (
  is_active = true
  or exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid()
      and p.active = true
      and upper(coalesce(p.role, '')) in ('ADMIN','SUPERADMIN')
  )
);

drop policy if exists "Admins manage Canva templates" on public.dv_accounting_canva_templates;
create policy "Admins manage Canva templates"
on public.dv_accounting_canva_templates for all
to authenticated
using (
  exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid()
      and p.active = true
      and upper(coalesce(p.role, '')) in ('ADMIN','SUPERADMIN')
  )
)
with check (
  exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid()
      and p.active = true
      and upper(coalesce(p.role, '')) in ('ADMIN','SUPERADMIN')
  )
);
create index if not exists idx_dv_accounting_canva_templates_active_category
on public.dv_accounting_canva_templates (is_active, category, sort_order, title);