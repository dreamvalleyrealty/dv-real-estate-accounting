-- Make admin-created trade submissions visible and editable by the agent they are assigned to.
-- Access is scoped to the authenticated user's matching agent profile.
drop policy if exists "assigned agent trade submission read" on public.dv_accounting_agent_trade_submissions;
create policy "assigned agent trade submission read"
on public.dv_accounting_agent_trade_submissions
for select to authenticated
using (agent_id = public.dv_accounting_my_agent_id());

drop policy if exists "assigned agent trade submission update" on public.dv_accounting_agent_trade_submissions;
create policy "assigned agent trade submission update"
on public.dv_accounting_agent_trade_submissions
for update to authenticated
using (
  agent_id = public.dv_accounting_my_agent_id()
  and status in ('DRAFT','NEEDS_CHANGES')
)
with check (
  agent_id = public.dv_accounting_my_agent_id()
  and status in ('DRAFT','NEEDS_CHANGES','SUBMITTED')
);

drop policy if exists "assigned agent trade document read" on public.dv_accounting_agent_trade_documents;
create policy "assigned agent trade document read"
on public.dv_accounting_agent_trade_documents
for select to authenticated
using (
  exists (
    select 1 from public.dv_accounting_agent_trade_submissions s
    where s.id = dv_accounting_agent_trade_documents.submission_id
      and s.agent_id = public.dv_accounting_my_agent_id()
  )
);

drop policy if exists "assigned agent trade document delete" on public.dv_accounting_agent_trade_documents;
create policy "assigned agent trade document delete"
on public.dv_accounting_agent_trade_documents
for delete to authenticated
using (
  exists (
    select 1 from public.dv_accounting_agent_trade_submissions s
    where s.id = dv_accounting_agent_trade_documents.submission_id
      and s.agent_id = public.dv_accounting_my_agent_id()
      and s.status in ('DRAFT','NEEDS_CHANGES')
  )
);

drop policy if exists "assigned agent read trade document storage" on storage.objects;
create policy "assigned agent read trade document storage"
on storage.objects
for select to authenticated
using (
  bucket_id = 'dv-trade-documents'
  and exists (
    select 1
    from public.dv_accounting_agent_trade_documents d
    join public.dv_accounting_agent_trade_submissions s on s.id = d.submission_id
    where d.storage_path = storage.objects.name
      and s.agent_id = public.dv_accounting_my_agent_id()
  )
);