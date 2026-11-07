alter table public.dv_open_house_event_signs
  add column if not exists collection_note text;

create or replace function public.dv_open_house_track_sign_collection_condition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent_id uuid;
  v_company_id uuid;
  v_event_date date;
  v_property_address text;
begin
  if new.status not in ('LOST', 'DAMAGED') or old.status is not distinct from new.status then
    return new;
  end if;

  select e.agent_id, e.company_id, e.event_date, e.property_address
    into v_agent_id, v_company_id, v_event_date, v_property_address
  from public.dv_open_house_events e
  where e.id = new.event_id;

  if v_agent_id is null then
    return new;
  end if;

  -- Consecutive open-house dates represent the same physical sign.
  -- Only count the final day in a consecutive run to avoid double-counting.
  if exists (
    select 1
    from public.dv_open_house_events next_event
    where next_event.company_id = v_company_id
      and next_event.agent_id = v_agent_id
      and lower(btrim(next_event.property_address)) = lower(btrim(v_property_address))
      and next_event.event_date = v_event_date + 1
  ) then
    return new;
  end if;

  insert into public.dv_open_house_agent_sign_inventory
    (company_id, agent_id, total_signs, lost_signs, damaged_signs, updated_by, updated_at)
  values
    (v_company_id, v_agent_id, 0,
      case when new.status = 'LOST' then 1 else 0 end,
      case when new.status = 'DAMAGED' then 1 else 0 end,
      auth.uid(), now())
  on conflict (agent_id) do update
    set lost_signs = coalesce(public.dv_open_house_agent_sign_inventory.lost_signs, 0)
          + case when new.status = 'LOST' then 1 else 0 end,
        damaged_signs = coalesce(public.dv_open_house_agent_sign_inventory.damaged_signs, 0)
          + case when new.status = 'DAMAGED' then 1 else 0 end,
        updated_by = auth.uid(),
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists dv_open_house_track_sign_collection_condition
  on public.dv_open_house_event_signs;
create trigger dv_open_house_track_sign_collection_condition
after update of status on public.dv_open_house_event_signs
for each row
execute function public.dv_open_house_track_sign_collection_condition();
