CREATE POLICY "agent upload documents after approval"
ON public.dv_accounting_agent_trade_documents
FOR INSERT TO authenticated
WITH CHECK (
  uploaded_by = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.dv_accounting_agent_trade_submissions s
    WHERE s.id = submission_id
      AND s.status = 'APPROVED'
      AND (s.submitted_by = auth.uid() OR s.agent_id = public.dv_accounting_my_agent_id())
      AND NOT EXISTS (
        SELECT 1
        FROM public.dv_accounting_transactions t
        WHERE t.id = s.transaction_id
          AND upper(COALESCE(t.status, '')) = 'PAID'
          AND upper(COALESCE(t.commission_payroll_status, '')) = 'PAID'
      )
  )
);
