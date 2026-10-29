create table if not exists public.dv_accounting_inventory_branch_stock (
 id uuid primary key default gen_random_uuid(),
 item_id uuid not null references public.dv_accounting_inventory_items(id) on delete cascade,
 branch_id uuid not null references public.dv_accounting_branches(id) on delete cascade,
 quantity numeric(12,2) not null default 0 check (quantity >= 0),
 updated_at timestamptz not null default now(),
 unique(item_id,branch_id)
);
create index if not exists dv_inventory_branch_stock_branch_idx on public.dv_accounting_inventory_branch_stock(branch_id,item_id);
alter table public.dv_accounting_inventory_branch_stock enable row level security;
drop policy if exists "Authenticated users can read inventory branch stock" on public.dv_accounting_inventory_branch_stock;
create policy "Authenticated users can read inventory branch stock" on public.dv_accounting_inventory_branch_stock for select to authenticated using (true);
drop policy if exists "Inventory managers can insert branch stock" on public.dv_accounting_inventory_branch_stock;
create policy "Inventory managers can insert branch stock" on public.dv_accounting_inventory_branch_stock for insert to authenticated with check (upper(coalesce((select p.role from public.dv_accounting_user_profiles p where p.user_id=auth.uid() limit 1),auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','STAFF'))='SUPERADMIN'
 or exists(select 1 from public.dv_accounting_user_permission_overrides u where u.user_id=auth.uid() and u.permission_code='inventory.manage' and u.allowed=true)
 or exists(select 1 from public.dv_accounting_user_profiles p join public.dv_accounting_role_permission_rules r on upper(r.role)=upper(p.role) where p.user_id=auth.uid() and r.permission_code='inventory.manage' and r.allowed=true));
drop policy if exists "Inventory managers can update branch stock" on public.dv_accounting_inventory_branch_stock;
create policy "Inventory managers can update branch stock" on public.dv_accounting_inventory_branch_stock for update to authenticated using (upper(coalesce((select p.role from public.dv_accounting_user_profiles p where p.user_id=auth.uid() limit 1),auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','STAFF'))='SUPERADMIN'
 or exists(select 1 from public.dv_accounting_user_permission_overrides u where u.user_id=auth.uid() and u.permission_code='inventory.manage' and u.allowed=true)
 or exists(select 1 from public.dv_accounting_user_profiles p join public.dv_accounting_role_permission_rules r on upper(r.role)=upper(p.role) where p.user_id=auth.uid() and r.permission_code='inventory.manage' and r.allowed=true)) with check (upper(coalesce((select p.role from public.dv_accounting_user_profiles p where p.user_id=auth.uid() limit 1),auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','STAFF'))='SUPERADMIN'
 or exists(select 1 from public.dv_accounting_user_permission_overrides u where u.user_id=auth.uid() and u.permission_code='inventory.manage' and u.allowed=true)
 or exists(select 1 from public.dv_accounting_user_profiles p join public.dv_accounting_role_permission_rules r on upper(r.role)=upper(p.role) where p.user_id=auth.uid() and r.permission_code='inventory.manage' and r.allowed=true));
drop policy if exists "Inventory managers can delete branch stock" on public.dv_accounting_inventory_branch_stock;
create policy "Inventory managers can delete branch stock" on public.dv_accounting_inventory_branch_stock for delete to authenticated using (upper(coalesce((select p.role from public.dv_accounting_user_profiles p where p.user_id=auth.uid() limit 1),auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','STAFF'))='SUPERADMIN'
 or exists(select 1 from public.dv_accounting_user_permission_overrides u where u.user_id=auth.uid() and u.permission_code='inventory.manage' and u.allowed=true)
 or exists(select 1 from public.dv_accounting_user_profiles p join public.dv_accounting_role_permission_rules r on upper(r.role)=upper(p.role) where p.user_id=auth.uid() and r.permission_code='inventory.manage' and r.allowed=true));