create table if not exists public.dv_open_house_agent_sign_inventory (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  total_signs integer not null default 0 check (total_signs >= 0),
  damaged_signs integer not null default 0 check (damaged_signs >= 0 and damaged_signs <= total_signs),
  notes text,
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agent_id)
);
create index if not exists dv_open_house_sign_inventory_company_idx
  on public.dv_open_house_agent_sign_inventory(company_id, agent_id);
alter table public.dv_open_house_agent_sign_inventory enable row level security;
grant select, insert, update on public.dv_open_house_agent_sign_inventory to authenticated;
drop policy if exists "open house sign inventory company read" on public.dv_open_house_agent_sign_inventory;
create policy "open house sign inventory company read"
on public.dv_open_house_agent_sign_inventory for select to authenticated
using (public.dv_open_house_company_access(company_id));
drop policy if exists "open house sign inventory agent or admin insert" on public.dv_open_house_agent_sign_inventory;
create policy "open house sign inventory agent or admin insert"
on public.dv_open_house_agent_sign_inventory for insert to authenticated
with check (
  public.dv_open_house_company_access(company_id)
  and exists (
    select 1 from public.dv_accounting_agents a
    where a.id = agent_id and a.company_id = company_id
      and (
        a.user_id = (select auth.uid())
        or lower(btrim(coalesce(a.email,''))) = lower(btrim(coalesce(auth.jwt()->>'email','')))
        or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
      )
  )
);
drop policy if exists "open house sign inventory agent or admin update" on public.dv_open_house_agent_sign_inventory;
create policy "open house sign inventory agent or admin update"
on public.dv_open_house_agent_sign_inventory for update to authenticated
using (
  public.dv_open_house_company_access(company_id)
  and exists (
    select 1 from public.dv_accounting_agents a
    where a.id = agent_id and a.company_id = company_id
      and (
        a.user_id = (select auth.uid())
        or lower(btrim(coalesce(a.email,''))) = lower(btrim(coalesce(auth.jwt()->>'email','')))
        or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
      )
  )
)
with check (
  public.dv_open_house_company_access(company_id)
  and exists (
    select 1 from public.dv_accounting_agents a
    where a.id = agent_id and a.company_id = company_id
      and (
        a.user_id = (select auth.uid())
        or lower(btrim(coalesce(a.email,''))) = lower(btrim(coalesce(auth.jwt()->>'email','')))
        or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
      )
  )
);
