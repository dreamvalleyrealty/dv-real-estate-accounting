-- Permit authorized transaction editors to record only manual invoice/statement entries.
-- The INSERT grant is constrained by the row-level security policy below.
GRANT INSERT ON TABLE public.dv_accounting_email_log TO authenticated;

DROP POLICY IF EXISTS "Record manually sent transaction documents" ON public.dv_accounting_email_log;
CREATE POLICY "Record manually sent transaction documents"
ON public.dv_accounting_email_log
FOR INSERT
TO authenticated
WITH CHECK (
  dv_accounting_has_permission_all_scope('transactions.edit'::text)
  AND document_type IN ('COMMISSION_INVOICE', 'SELLER_COMMISSION_STATEMENT')
  AND status = 'SENT'
  AND attachment_name = 'Manual record (sent outside this system)'
  AND sent_by = auth.uid()
);
