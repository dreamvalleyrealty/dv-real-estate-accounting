-- Add an optional explanatory reason for DFT separately from trust-release authority.
CREATE OR REPLACE FUNCTION public.dv_accounting_mark_transaction_dft(
 p_transaction_id uuid,p_refund_bank_account_id uuid,p_refund_date date,p_refund_method text,
 p_refund_reference text,p_authority_reference text,p_release_authorized boolean,p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE t public.dv_accounting_transactions%ROWTYPE; v_result jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in to mark a deal DFT'; END IF;
 IF NOT public.dv_accounting_is_trade_admin() THEN RAISE EXCEPTION 'Only an administrator with trade management permission can mark a deal DFT'; END IF;
 SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
 IF upper(coalesce(nullif(t.deal_status,''),'DRAFT'))<>'FIRM' THEN RAISE EXCEPTION 'DFT is only available after the deal has become Firm'; END IF;
 v_result:=public.dv_accounting_mark_transaction_dft_internal(p_transaction_id,p_refund_bank_account_id,p_refund_date,p_refund_method,p_refund_reference,p_authority_reference,p_release_authorized);
 UPDATE public.dv_accounting_transactions
 SET deal_status='DFT',deal_status_reason=nullif(trim(coalesce(p_reason,'')),''),deal_status_changed_at=now(),deal_status_changed_by=auth.uid()
 WHERE id=p_transaction_id;
 UPDATE public.dv_accounting_agent_trade_submissions SET deal_status='DFT',updated_at=now() WHERE transaction_id=p_transaction_id;
 INSERT INTO public.dv_accounting_deal_status_history(transaction_id,previous_status,new_status,reason,changed_by)
 VALUES(p_transaction_id,'FIRM','DFT',nullif(trim(coalesce(p_reason,'')),''),auth.uid());
 RETURN coalesce(v_result,'{}'::jsonb)||jsonb_build_object('deal_status','DFT');
END;$function$;
REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.dv_accounting_mark_transaction_dft(
 p_transaction_id uuid,p_refund_bank_account_id uuid,p_refund_date date,p_refund_method text,
 p_refund_reference text,p_authority_reference text,p_release_authorized boolean
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
 SELECT public.dv_accounting_mark_transaction_dft(
  p_transaction_id,p_refund_bank_account_id,p_refund_date,p_refund_method,
  p_refund_reference,p_authority_reference,p_release_authorized,NULL::text
 );
$function$;
REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean) TO authenticated,service_role;
