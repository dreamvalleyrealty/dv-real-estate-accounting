-- Add emergency contact details to agent master records.
-- Keep spouse_name temporarily for backwards compatibility with older records.
alter table public.dv_accounting_agents
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_number text;

update public.dv_accounting_agents
set emergency_contact_name = spouse_name
where emergency_contact_name is null
  and spouse_name is not null;
