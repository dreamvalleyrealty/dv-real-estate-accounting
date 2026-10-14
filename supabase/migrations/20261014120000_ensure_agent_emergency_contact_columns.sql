-- Ensure agent emergency-contact columns exist even if an earlier migration was skipped.
alter table public.dv_accounting_agents
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_number text;

update public.dv_accounting_agents
set emergency_contact_name = spouse_name
where emergency_contact_name is null
  and spouse_name is not null;

notify pgrst, 'reload schema';
