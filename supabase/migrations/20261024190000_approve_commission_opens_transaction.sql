-- Commission approval moves a draft transaction into the OPEN workflow.
CREATE OR REPLACE FUNCTION public.dv_accounting_approve_transaction_commission(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
BEGIN
  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;
  IF t.status NOT IN ('DRAFT', 'OPEN') THEN
    RAISE EXCEPTION 'Only draft or open transactions can have commission approved';
  END IF;
  IF COALESCE(t.gross_commission, 0) <= 0 AND COALESCE(t.agent_commission, 0) <= 0 THEN
    RAISE EXCEPTION 'Enter and verify the commission amount before approval';
  END IF;

  UPDATE public.dv_accounting_transactions
  SET status = 'OPEN',
      commission_approved = true,
      commission_approved_at = COALESCE(commission_approved_at, now()),
      commission_approved_amount = COALESCE(t.gross_commission, 0),
      commission_approved_agent_payable = COALESCE(t.agent_commission, 0)
  WHERE id = t.id;

  RETURN jsonb_build_object(
    'ok', true,
    'transaction_id', t.id,
    'status', 'OPEN',
    'approved_amount', COALESCE(t.gross_commission, 0),
    'agent_payable', COALESCE(t.agent_commission, 0)
  );
END
$function$;
