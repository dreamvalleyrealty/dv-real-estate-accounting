-- Keep the deal lifecycle in sync when the accounting close workflow succeeds.
ALTER FUNCTION public.dv_accounting_close_transaction(uuid)
  RENAME TO dv_accounting_close_transaction_internal;
REVOKE ALL ON FUNCTION public.dv_accounting_close_transaction_internal(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_close_transaction(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to close a transaction';
  END IF;
  IF NOT public.dv_accounting_is_trade_admin() THEN
    RAISE EXCEPTION 'Only an administrator with trade management permission can close a transaction';
  END IF;

  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF upper(coalesce(nullif(t.deal_status,''),'DRAFT')) <> 'FIRM' THEN
    RAISE EXCEPTION 'A deal must be Firm before it can be closed';
  END IF;

  v_result := public.dv_accounting_close_transaction_internal(p_transaction_id);

  UPDATE public.dv_accounting_transactions
  SET deal_status = 'CLOSED',
      deal_status_changed_at = now(),
      deal_status_changed_by = auth.uid()
  WHERE id = p_transaction_id;

  UPDATE public.dv_accounting_agent_trade_submissions
  SET deal_status = 'CLOSED',
      updated_at = now()
  WHERE transaction_id = p_transaction_id;

  INSERT INTO public.dv_accounting_deal_status_history
    (transaction_id, previous_status, new_status, reason, changed_by)
  VALUES
    (p_transaction_id, 'FIRM', 'CLOSED', NULL, auth.uid());

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object('deal_status','CLOSED');
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_close_transaction(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_close_transaction(uuid) TO authenticated, service_role;
