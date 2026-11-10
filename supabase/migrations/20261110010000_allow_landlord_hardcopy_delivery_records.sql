-- Allow authorized transaction editors to record landlord statements handed over as hard copies.
-- This is a delivery log only: no email address or email delivery is involved.
GRANT INSERT ON TABLE public.dv_accounting_email_log TO authenticated;

DROP POLICY IF EXISTS "Record manually delivered landlord hard copies" ON public.dv_accounting_email_log;
CREATE POLICY "Record manually delivered landlord hard copies"
ON public.dv_accounting_email_log
FOR INSERT
TO authenticated
WITH CHECK (
  dv_accounting_has_permission_all_scope('transactions.edit'::text)
  AND document_type = 'SELLER_COMMISSION_STATEMENT_HARDCOPY'
  AND status = 'SENT'
  AND attachment_name = 'Hard copy delivery record'
  AND sent_by = auth.uid()
);
