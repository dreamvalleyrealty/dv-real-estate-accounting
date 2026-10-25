-- Allow the assigned agent to upload missing/replacement paperwork after transfer.
-- Keep the upload restricted to the authenticated user's own folder and their submission.
DROP POLICY IF EXISTS "trade docs upload own folder or admin" ON storage.objects;
CREATE POLICY "trade docs upload own folder or admin"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND EXISTS (
    SELECT 1
    FROM public.dv_accounting_agent_trade_submissions s
    WHERE s.id::text = (storage.foldername(name))[2]
      AND s.status IN ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED')
      AND (
        s.submitted_by = auth.uid()
        OR s.agent_id = public.dv_accounting_my_agent_id()
        OR public.dv_accounting_is_trade_submission_admin()
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.dv_accounting_transactions t
        WHERE t.id = s.transaction_id
          AND upper(coalesce(t.status,'')) = 'PAID'
          AND upper(coalesce(t.commission_payroll_status,'')) = 'PAID'
      )
  )
);
