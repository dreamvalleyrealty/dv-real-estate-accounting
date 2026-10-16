-- Allow the authenticated agent assigned to a draft or needs-changes trade to upload documents.
-- The uploader must be the current user and must own or be assigned to the submission.
create policy "assigned agent trade document upload"
on public.dv_accounting_agent_trade_documents
for insert
to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (
    select 1
    from public.dv_accounting_agent_trade_submissions s
    where s.id = dv_accounting_agent_trade_documents.submission_id
      and s.status in ('DRAFT', 'NEEDS_CHANGES')
      and (
        s.submitted_by = auth.uid()
        or s.agent_id = public.dv_accounting_my_agent_id()
      )
  )
);
