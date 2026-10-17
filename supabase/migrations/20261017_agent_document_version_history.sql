-- Configurable agent document renewal/version history.
-- Existing document rows and stored files are intentionally preserved.
alter table public.dv_accounting_personnel_documents
  add column if not exists version_group_id uuid,
  add column if not exists version_number integer,
  add column if not exists is_current boolean,
  add column if not exists archived_at timestamptz;

update public.dv_accounting_personnel_documents
set version_number = 1
where version_number is null;

update public.dv_accounting_personnel_documents
set is_current = true
where is_current is null;

create index if not exists dv_accounting_personnel_documents_version_group_idx
  on public.dv_accounting_personnel_documents (version_group_id, version_number desc);

create index if not exists dv_accounting_personnel_documents_agent_type_current_idx
  on public.dv_accounting_personnel_documents (agent_id, document_type, is_current);

-- Seed/merge requested defaults without removing any existing document type settings.
-- Existing custom document types are retained; only the six named policies are replaced.
with desired as (
  select jsonb_build_array(
    jsonb_build_object('name','RECO Registration','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','E&O Insurance','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','Photo ID','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','Training Certificates','expiryRequired',false,'renewalHistoryEnabled',false),
    jsonb_build_object('name','Independent Contractor Agreement','expiryRequired',false,'renewalHistoryEnabled',false),
    jsonb_build_object('name','Other Supporting Documents','expiryRequired',false,'renewalHistoryEnabled',false)
  ) as items
)
insert into public.dv_accounting_settings (company_id, key, value)
select c.id, 'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
       coalesce(existing.value, '[]'::jsonb)
from public.dv_accounting_companies c
left join public.dv_accounting_settings existing
  on existing.company_id = c.id
 and existing.key = 'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS'
where not exists (
  select 1 from public.dv_accounting_settings s
  where s.company_id = c.id and s.key = 'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS'
)
on conflict (company_id, key) do nothing;

with desired as (
  select jsonb_build_array(
    jsonb_build_object('name','RECO Registration','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','E&O Insurance','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','Photo ID','expiryRequired',true,'renewalHistoryEnabled',true),
    jsonb_build_object('name','Training Certificates','expiryRequired',false,'renewalHistoryEnabled',false),
    jsonb_build_object('name','Independent Contractor Agreement','expiryRequired',false,'renewalHistoryEnabled',false),
    jsonb_build_object('name','Other Supporting Documents','expiryRequired',false,'renewalHistoryEnabled',false)
  ) as items
)
update public.dv_accounting_settings s
set value = (
  select coalesce(jsonb_agg(item), '[]'::jsonb)
  from jsonb_array_elements(coalesce(s.value, '[]'::jsonb)) item
  where item->>'name' not in (
    'RECO Registration','E&O Insurance','Photo ID','Training Certificates',
    'Independent Contractor Agreement','Other Supporting Documents'
  )
) || desired.items
from desired
where s.key = 'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS';

