-- Permit authorized brokerage admins to upload documents to approved,
-- closed and paid trades. Agent upload restrictions remain unchanged.

drop policy if exists "trade docs upload own folder or admin" on storage.objects;
create policy "trade docs upload own folder or admin"
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
  and exists (
    select 1
    from public.dv_accounting_agent_trade_submissions s
    where s.id::text = (storage.foldername(objects.name))[2]
      and s.status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED')
      and (
        (
          (s.submitted_by = auth.uid() or s.agent_id = public.dv_accounting_my_agent_id())
          and not exists (
            select 1
            from public.dv_accounting_transactions t
            where t.id = s.transaction_id
              and upper(coalesce(t.status,'')) = 'PAID'
              and upper(coalesce(t.commission_payroll_status,'')) = 'PAID'
          )
        )
        or public.dv_accounting_is_trade_submission_admin()
      )
  )
);

drop policy if exists "trade admin document upload" on public.dv_accounting_agent_trade_documents;
create policy "trade admin document upload"
on public.dv_accounting_agent_trade_documents
for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and public.dv_accounting_is_trade_submission_admin()
  and exists (
    select 1
    from public.dv_accounting_agent_trade_submissions s
    where s.id = submission_id
      and s.status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED')
  )
);
