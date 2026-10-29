create table if not exists public.dv_accounting_inventory_items (
 id uuid primary key default gen_random_uuid(),
 item_code text not null unique,
 item_name text not null,
 category text not null default 'OFFICE',
 item_type text not null default 'LOANABLE' check (item_type in ('LOANABLE','GIFT','SELLABLE','SERVICE')),
 description text,
 stock_quantity numeric(12,2) not null default 0 check (stock_quantity >= 0),
 reorder_level numeric(12,2) not null default 0 check (reorder_level >= 0),
 unit_cost numeric(12,2) not null default 0,
 sale_price numeric(12,2) not null default 0,
 tax_rate numeric(5,2) not null default 13,
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.dv_accounting_inventory_movements (
 id uuid primary key default gen_random_uuid(),
 item_id uuid not null references public.dv_accounting_inventory_items(id),
 movement_type text not null check (movement_type in ('STOCK_IN','BORROW','RETURN','GIFT','SALE','SERVICE','ADJUSTMENT')),
 quantity numeric(12,2) not null check (quantity > 0),
 returned_quantity numeric(12,2) not null default 0 check (returned_quantity >= 0),
 agent_id uuid references public.dv_accounting_agents(id) on delete set null,
 branch_id uuid references public.dv_accounting_branches(id) on delete set null,
 transaction_date date not null default current_date,
 due_date date,
 status text not null default 'COMPLETED' check (status in ('OUT','PARTIAL','RETURNED','COMPLETED','CANCELLED')),
 unit_price numeric(12,2) not null default 0,
 subtotal numeric(12,2) not null default 0,
 hst_amount numeric(12,2) not null default 0,
 total_amount numeric(12,2) not null default 0,
 reference text,
 notes text,
 created_by uuid,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists dv_inventory_items_active_type_idx on public.dv_accounting_inventory_items(is_active,item_type);
create index if not exists dv_inventory_movements_item_date_idx on public.dv_accounting_inventory_movements(item_id,transaction_date desc);
create index if not exists dv_inventory_movements_agent_due_idx on public.dv_accounting_inventory_movements(agent_id,due_date,status);
alter table public.dv_accounting_inventory_items enable row level security;
alter table public.dv_accounting_inventory_movements enable row level security;
drop policy if exists "Authenticated users can read inventory items" on public.dv_accounting_inventory_items;
create policy "Authenticated users can read inventory items" on public.dv_accounting_inventory_items for select to authenticated using (true);
drop policy if exists "Authenticated users can manage inventory items" on public.dv_accounting_inventory_items;
create policy "Authenticated users can manage inventory items" on public.dv_accounting_inventory_items for all to authenticated using (true) with check (true);
drop policy if exists "Authenticated users can read inventory movements" on public.dv_accounting_inventory_movements;
create policy "Authenticated users can read inventory movements" on public.dv_accounting_inventory_movements for select to authenticated using (true);
drop policy if exists "Authenticated users can manage inventory movements" on public.dv_accounting_inventory_movements;
create policy "Authenticated users can manage inventory movements" on public.dv_accounting_inventory_movements for all to authenticated using (true) with check (true);
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
values
 ('inventory.view','Inventory Control','View inventory','View office inventory, agent loans, gift stock, sales, and services.',80),
 ('inventory.manage','Inventory Control','Manage inventory','Create items, receive stock, issue/return items, record giveaways and sales, and manage inventory transactions.',81)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description;