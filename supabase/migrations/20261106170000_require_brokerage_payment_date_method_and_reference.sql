-- Payment date, method and reference are required for brokerage share transfers.
-- The same function definition was applied to the production DV-Back-Office project.
CREATE OR REPLACE FUNCTION public.dv_accounting_pay_our_brokerage(
 p_transaction_id uuid, p_payment_date date, p_payment_method text, p_payment_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE
 v_company_id uuid; v_tx text; v_gross numeric(14,2); v_split numeric(7,4); v_hst numeric(7,4);
 v_admin numeric(14,2):=0; v_fees numeric(14,2):=0; v_amount numeric(14,2);
 v_source uuid; v_client text; v_matter text; v_dest uuid; v_ref text; v_role text;
 v_method text:=upper(trim(coalesce(p_payment_method,''))); v_detail text; v_exists uuid; v_cheque uuid; v_cheque_ref text;
BEGIN
 SELECT upper(coalesce(role,'')) INTO v_role FROM public.dv_accounting_user_profiles WHERE user_id=auth.uid();
 IF v_role NOT IN ('SUPERADMIN','SUPERADMINISTRATOR') THEN RAISE EXCEPTION 'Only a SuperAdmin may post this transfer.'; END IF;
 IF p_transaction_id IS NULL OR p_payment_date IS NULL THEN RAISE EXCEPTION 'Transaction and payment date are required.'; END IF;
 IF v_method NOT IN ('EFT','CHEQUE','INTERNAL_TRANSFER') THEN RAISE EXCEPTION 'Choose EFT, cheque or internal bank transfer.'; END IF;
 IF v_method IN ('EFT','CHEQUE') AND coalesce(trim(p_payment_reference),'')='' THEN RAISE EXCEPTION 'Payment reference is required.'; END IF;
 v_detail:=v_method||CASE WHEN coalesce(trim(p_payment_reference),'')<>'' THEN ' - '||trim(p_payment_reference) ELSE '' END;
 SELECT t.company_id,t.transaction_number,round(coalesce(nullif(t.commission_approved_amount,0),nullif(t.gross_commission,0),0)::numeric,2)
 INTO v_company_id,v_tx,v_gross FROM public.dv_accounting_transactions t
 WHERE t.id=p_transaction_id AND upper(coalesce(t.status,''))='CLOSED' FOR UPDATE;
 IF NOT FOUND OR v_company_id IS NULL THEN RAISE EXCEPTION 'Closed transaction was not found.'; END IF;
 SELECT split_percent INTO v_split FROM public.dv_accounting_transaction_agent_info
 WHERE transaction_id=p_transaction_id ORDER BY created_at DESC LIMIT 1;
 IF v_split IS NULL OR v_split<0 OR v_split>100 THEN RAISE EXCEPTION 'Valid agent split is required.'; END IF;
 IF v_split<=0.0001 THEN
  SELECT round(coalesce(listing_commission_amount,0)::numeric,2) INTO v_gross
  FROM public.dv_accounting_seller_settlements WHERE transaction_id=p_transaction_id ORDER BY updated_at DESC LIMIT 1;
  IF coalesce(v_gross,0)<=0 THEN RAISE EXCEPTION 'Listing-side commission was not found.'; END IF;
 ELSE
  SELECT q.id,coalesce(nullif(trim(q.payment_reference),''),nullif(trim(q.cheque_number),'')),coalesce(q.total_fees,0)
  INTO v_cheque,v_cheque_ref,v_fees FROM public.dv_accounting_commission_cheques q
  JOIN public.dv_accounting_commissions c ON c.id=q.commission_id
  WHERE c.transaction_id=p_transaction_id AND upper(coalesce(q.status,''))='ISSUED'
  ORDER BY q.created_at DESC LIMIT 1;
  IF v_cheque IS NULL OR coalesce(v_cheque_ref,'')='' THEN RAISE EXCEPTION 'Record agent payment reference first.'; END IF;
  SELECT coalesce(max(admin_fee),0) INTO v_admin FROM public.dv_accounting_transaction_agent_info WHERE transaction_id=p_transaction_id;
 END IF;
 SELECT coalesce((SELECT hst_rate FROM public.dv_accounting_transaction_commissions
 WHERE transaction_id=p_transaction_id AND upper(side)='LISTING' ORDER BY created_at DESC LIMIT 1),13) INTO v_hst;
 v_amount:=round(v_gross*(100-v_split)/100*(1+v_hst/100)+v_admin*v_hst/100+v_fees,2);
 IF v_gross<=0 OR v_amount<=0 THEN RAISE EXCEPTION 'Calculated brokerage amount must be positive.'; END IF;
 v_ref:='OUR-BROKERAGE:'||p_transaction_id::text;
 SELECT id INTO v_exists FROM public.dv_accounting_trust_transactions
 WHERE reference=v_ref AND trust_account_type='COMMISSION_TRUST' AND direction='DISBURSEMENT' AND status='POSTED' LIMIT 1;
 IF v_exists IS NOT NULL THEN RETURN jsonb_build_object('already_posted',true,'amount',v_amount,'reference',v_ref); END IF;
 SELECT id INTO v_source FROM public.dv_accounting_bank_accounts
 WHERE company_id=v_company_id AND account_type='COMMISSION_TRUST' AND active IS TRUE ORDER BY created_at LIMIT 1;
 IF v_source IS NULL THEN RAISE EXCEPTION 'Active Commission Trust account not found.'; END IF;
 SELECT client_name,matter INTO v_client,v_matter FROM public.dv_accounting_trust_transactions
 WHERE transaction_id=p_transaction_id AND company_id=v_company_id AND trust_account_type='COMMISSION_TRUST'
 AND direction='DEPOSIT' AND status='POSTED' ORDER BY created_at DESC LIMIT 1;
 IF coalesce(trim(v_client),'')='' THEN RAISE EXCEPTION 'Posted Commission Trust deposit was not found.'; END IF;
 SELECT id INTO v_dest FROM public.dv_accounting_bank_accounts
 WHERE company_id=v_company_id AND account_type='OPERATING' AND active IS TRUE ORDER BY created_at LIMIT 1;
 IF v_dest IS NULL THEN RAISE EXCEPTION 'Active General Operating account not found.'; END IF;
 PERFORM public.dv_accounting_post_trust_transaction(v_company_id,v_source,p_transaction_id,p_payment_date,
 'COMMISSION_TRUST','DISBURSEMENT',v_client,coalesce(nullif(v_matter,''),v_tx),
 'Brokerage share transfer to General Operating - '||v_tx||' ('||v_detail||')',v_amount,v_ref);
 INSERT INTO public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference,transaction_id)
 SELECT v_dest,p_payment_date,'Brokerage share received from Commission Trust - '||v_tx||' ('||v_detail||')',
 v_amount,false,v_ref,p_transaction_id
 WHERE NOT EXISTS(SELECT 1 FROM public.dv_accounting_bank_transactions WHERE reference=v_ref AND bank_account_id=v_dest);
 RETURN jsonb_build_object('already_posted',false,'amount',v_amount,'reference',v_ref,
 'payment_date',p_payment_date,'payment_method',v_method,'payment_reference',p_payment_reference);
END; $fn$;
REVOKE ALL ON FUNCTION public.dv_accounting_pay_our_brokerage(uuid,date,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_pay_our_brokerage(uuid,date,text,text) TO authenticated;
