-- Refund a buyer deposit for a terminated conditional deal without changing its lifecycle status.
CREATE OR REPLACE FUNCTION public.dv_accounting_refund_terminated_buyer_deposit(
  p_transaction_id uuid,
  p_mutual_release_document_id uuid,
  p_refund_bank_account_id uuid,
  p_refund_date date,
  p_refund_method text,
  p_refund_reference text,
  p_authority_reference text,
  p_release_authorized boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  tr public.dv_accounting_transaction_trust%ROWTYPE;
  doc public.dv_accounting_agent_trade_documents%ROWTYPE;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in to refund a buyer deposit'; END IF;
  IF NOT public.dv_accounting_is_trade_admin() THEN RAISE EXCEPTION 'Only an administrator with trade management permission can refund a buyer deposit'; END IF;
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF upper(coalesce(nullif(t.deal_status,''),'DRAFT')) <> 'TERMINATED' THEN RAISE EXCEPTION 'This refund process is only available for a terminated deal'; END IF;
  IF coalesce(t.deposit_refunded,false) THEN RAISE EXCEPTION 'The buyer deposit has already been refunded'; END IF;
  SELECT * INTO doc FROM public.dv_accounting_agent_trade_documents
    WHERE id=p_mutual_release_document_id AND transaction_id=p_transaction_id
      AND upper(coalesce(document_type,''))='MUTUAL_RELEASE' AND upper(coalesce(match_status,''))='MATCH'
    FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'An approved Mutual Release linked to this transaction is required before refunding the deposit'; END IF;
  SELECT * INTO tr FROM public.dv_accounting_transaction_trust
    WHERE transaction_id=p_transaction_id AND upper(coalesce(we_hold_deposit,''))='YES'
      AND upper(coalesce(received,''))='YES' AND amount>0
    ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No buyer deposit received and held by Dream Valley was found for this transaction'; END IF;
  IF NOT coalesce(p_release_authorized,false) OR nullif(trim(coalesce(p_authority_reference,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Confirm the approved written release authority and enter its reference before issuing the refund';
  END IF;
  v_result := public.dv_accounting_mark_transaction_dft_internal(
    p_transaction_id,p_refund_bank_account_id,coalesce(p_refund_date,current_date),
    p_refund_method,p_refund_reference,p_authority_reference,p_release_authorized
  );
  RETURN coalesce(v_result,'{}'::jsonb) || jsonb_build_object(
    'deal_status','TERMINATED','mutual_release_document_id',doc.id,
    'refund_amount',tr.amount,'deposit_refunded',true
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.dv_accounting_refund_terminated_buyer_deposit(uuid,uuid,uuid,date,text,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_refund_terminated_buyer_deposit(uuid,uuid,uuid,date,text,text,text,boolean) TO authenticated,service_role;
COMMENT ON FUNCTION public.dv_accounting_refund_terminated_buyer_deposit(uuid,uuid,uuid,date,text,text,text,boolean)
IS 'Refunds a deposit for a TERMINATED deal only after the linked Mutual Release is approved; preserves TERMINATED deal lifecycle status and posts through the protected DFT accounting routine.';
