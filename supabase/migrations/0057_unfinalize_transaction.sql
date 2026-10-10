-- 0057: allow a finalized transaction to be safely returned to DRAFT for correction.
-- This is intentionally limited to FINALIZED trades. CLOSED trades may already have
-- trust postings/payroll entries and require a separate accounting reversal workflow.
CREATE OR REPLACE FUNCTION public.dv_accounting_unfinalize_transaction(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
BEGIN
  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id=p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  IF t.status <> 'FINALIZED' THEN
    RAISE EXCEPTION 'Only FINALIZED transactions can be unfinalized. Current status: %', COALESCE(t.status,'UNKNOWN');
  END IF;

  UPDATE public.dv_accounting_transactions
  SET status='DRAFT',
      commission_approved=false,
      commission_approved_at=NULL,
      commission_approved_amount=0,
      commission_approved_agent_payable=0,
      finalized_date=NULL,
      commission_payroll_status=NULL
  WHERE id=t.id;

  RETURN jsonb_build_object(
    'ok',true,
    'transaction_id',t.id,
    'previous_status','FINALIZED',
    'status','DRAFT'
  );
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_unfinalize_transaction(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_unfinalize_transaction(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
