create table if not exists public.dv_open_house_sign_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  from_agent_id uuid not null references public.dv_accounting_agents(id),
  to_agent_id uuid not null references public.dv_accounting_agents(id),
  quantity integer not null check (quantity > 0),
  notes text,
  transferred_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint dv_open_house_sign_transfers_different_agents check (from_agent_id <> to_agent_id)
);
create index if not exists dv_open_house_sign_transfers_company_created_idx
  on public.dv_open_house_sign_transfers(company_id, created_at desc);
alter table public.dv_open_house_sign_transfers enable row level security;
grant select, insert on public.dv_open_house_sign_transfers to authenticated;

drop policy if exists "open house sign transfers admin read" on public.dv_open_house_sign_transfers;
create policy "open house sign transfers admin read"
on public.dv_open_house_sign_transfers for select to authenticated
using (
  public.dv_open_house_company_access(company_id)
  and public.dv_open_house_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
);
drop policy if exists "open house sign transfers admin insert" on public.dv_open_house_sign_transfers;
create policy "open house sign transfers admin insert"
on public.dv_open_house_sign_transfers for insert to authenticated
with check (
  public.dv_open_house_company_access(company_id)
  and public.dv_open_house_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
  and exists (select 1 from public.dv_accounting_agents a where a.id = from_agent_id and a.company_id = company_id)
  and exists (select 1 from public.dv_accounting_agents a where a.id = to_agent_id and a.company_id = company_id)
);

create or replace function public.dv_open_house_apply_sign_transfer()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_available integer;
begin
  select total_signs - lost_signs - damaged_signs
    into v_available
    from public.dv_open_house_agent_sign_inventory
   where company_id = new.company_id and agent_id = new.from_agent_id
   for update;

  if not found then
    raise exception 'The sending agent has no sign inventory recorded.';
  end if;
  if v_available < new.quantity then
    raise exception 'Transfer exceeds the sending agent available signs (% available).', v_available;
  end if;

  update public.dv_open_house_agent_sign_inventory
     set total_signs = total_signs - new.quantity,
         updated_by = new.transferred_by,
         updated_at = now()
   where company_id = new.company_id and agent_id = new.from_agent_id;

  insert into public.dv_open_house_agent_sign_inventory
    (company_id, agent_id, total_signs, lost_signs, damaged_signs, updated_by, updated_at)
  values
    (new.company_id, new.to_agent_id, new.quantity, 0, 0, new.transferred_by, now())
  on conflict (agent_id) do update
    set total_signs = public.dv_open_house_agent_sign_inventory.total_signs + excluded.total_signs,
        updated_by = excluded.updated_by,
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists dv_open_house_sign_transfer_apply on public.dv_open_house_sign_transfers;
create trigger dv_open_house_sign_transfer_apply
before insert on public.dv_open_house_sign_transfers
for each row execute function public.dv_open_house_apply_sign_transfer();
