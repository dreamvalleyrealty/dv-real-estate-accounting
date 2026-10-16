-- Permit authorized trade administrators to attach documents to trade submissions.
-- Agent uploads remain governed by the existing agent trade document insert policy.
-- Keep the restriction that fully paid transactions cannot receive further document uploads.
create policy "trade admin document upload"
on public.dv_accounting_agent_trade_documents
for insert
to authenticated
with check (
  uploaded_by = auth.uid()
  and public.dv_accounting_is_trade_submission_admin()
  and exists (
    select 1
    from public.dv_accounting_agent_trade_submissions s
    where s.id = dv_accounting_agent_trade_documents.submission_id
      and s.status in ('DRAFT', 'SUBMITTED', 'NEEDS_CHANGES', 'APPROVED')
      and not exists (
        select 1
        from public.dv_accounting_transactions t
        where t.id = s.transaction_id
          and upper(coalesce(t.status, '')) = 'PAID'
          and upper(coalesce(t.commission_payroll_status, '')) = 'PAID'
      )
  )
);
