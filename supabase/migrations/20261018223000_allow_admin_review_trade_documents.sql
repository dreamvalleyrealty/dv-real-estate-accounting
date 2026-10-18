CREATE POLICY "admin can review trade documents"
ON public.dv_accounting_agent_trade_documents
FOR UPDATE
TO authenticated
USING (public.dv_accounting_is_trade_submission_admin())
WITH CHECK (public.dv_accounting_is_trade_submission_admin());
