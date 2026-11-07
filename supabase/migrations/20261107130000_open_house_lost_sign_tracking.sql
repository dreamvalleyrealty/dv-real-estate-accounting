alter table public.dv_open_house_agent_sign_inventory
  add column if not exists lost_signs integer not null default 0;
alter table public.dv_open_house_agent_sign_inventory
  drop constraint if exists dv_open_house_agent_sign_inventory_damaged_signs_check;
alter table public.dv_open_house_agent_sign_inventory
  add constraint dv_open_house_agent_sign_inventory_lost_damaged_check
  check (lost_signs >= 0 and damaged_signs >= 0 and lost_signs + damaged_signs <= total_signs);