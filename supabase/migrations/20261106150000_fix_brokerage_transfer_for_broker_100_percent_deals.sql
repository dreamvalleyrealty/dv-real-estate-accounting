-- Correct brokerage-share transfer for 100% brokerage transactions.
-- A 0% agent split uses the seller settlement's listing-side commission,
-- not the transaction's approved cooperating-brokerage commission.
CREATE OR REPLACE FUNCTION public.dv_accounting_pay_our_brokerage(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $function$
DECLARE
  v_company_id uuid;
  v_transaction_number text;
  v_gross numeric(14,2);
  v_agent_split numeric(7,4);
  v_hst_rate numeric(7,4);
  v_admin_fee numeric(14,2) := 0;
  v_cheque_fees numeric(14,2) := 0;
  v_amount numeric(14,2);
  v_payment_date date := current_date;
  v_cheque_reference text;
  v_cheque_id uuid;
  v_source_account_id uuid;
  v_source_client text;
  v_source_matter text;
  v_destination_account_id uuid;
  v_reference text;
  v_existing_id uuid;
  v_role text;
BEGIN
  SELECT upper(coalesce(role,'')) INTO v_role
  FROM public.dv_accounting_user_profiles WHERE user_id=auth.uid();
  IF v_role NOT IN ('SUPERADMIN','SUPERADMINISTRATOR') THEN
    RAISE EXCEPTION 'Only a SuperAdmin may post the brokerage share transfer.';
  END IF;
  IF p_transaction_id IS NULL THEN RAISE EXCEPTION 'Transaction is required.'; END IF;

  SELECT t.company_id,t.transaction_number,
         round(coalesce(nullif(t.commission_approved_amount,0),nullif(t.gross_commission,0),0)::numeric,2)
    INTO v_company_id,v_transaction_number,v_gross
  FROM public.dv_accounting_transactions t
  WHERE t.id=p_transaction_id AND upper(coalesce(t.status,''))='CLOSED'
  FOR UPDATE;
  IF NOT FOUND OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'Closed transaction was not found.';
  END IF;

  SELECT i.split_percent INTO v_agent_split
  FROM public.dv_accounting_transaction_agent_info i
  WHERE i.transaction_id=p_transaction_id
  ORDER BY i.created_at DESC LIMIT 1;
  IF v_agent_split IS NULL OR v_agent_split<0 OR v_agent_split>100 THEN
    RAISE EXCEPTION 'A valid agent split percentage is required to calculate the brokerage share.';
  END IF;

  IF v_agent_split<=0.0001 THEN
    -- Broker 100% deal: only the listing-side commission belongs to this brokerage.
    SELECT round(coalesce(s.listing_commission_amount,0)::numeric,2)
      INTO v_gross
    FROM public.dv_accounting_seller_settlements s
    WHERE s.transaction_id=p_transaction_id
    ORDER BY s.updated_at DESC LIMIT 1;
    IF coalesce(v_gross,0)<=0 THEN
      RAISE EXCEPTION 'No listing-side commission was found in the seller settlement. Review the seller commission before transferring.';
    END IF;
  ELSE
    SELECT q.id,
           coalesce(nullif(trim(q.payment_reference),''),nullif(trim(q.cheque_number),'')),
           coalesce(q.total_fees,0)
      INTO v_cheque_id,v_cheque_reference,v_cheque_fees
    FROM public.dv_accounting_commission_cheques q
    JOIN public.dv_accounting_commissions c ON c.id=q.commission_id
    WHERE c.transaction_id=p_transaction_id AND upper(coalesce(q.status,''))='ISSUED'
    ORDER BY q.created_at DESC LIMIT 1;
    IF v_cheque_id IS NULL OR coalesce(v_cheque_reference,'')='' THEN
      RAISE EXCEPTION 'Record and issue the agent commission payment with a cheque/EFT reference first.';
    END IF;
    SELECT coalesce(max(i.admin_fee),0) INTO v_admin_fee
    FROM public.dv_accounting_transaction_agent_info i
    WHERE i.transaction_id=p_transaction_id;
  END IF;

  SELECT coalesce(
    (SELECT tc.hst_rate FROM public.dv_accounting_transaction_commissions tc
     WHERE tc.transaction_id=p_transaction_id AND upper(tc.side)='LISTING'
     ORDER BY tc.created_at DESC LIMIT 1),13
  ) INTO v_hst_rate;

  v_amount := round(
    (v_gross*(100-v_agent_split)/100)
    + ((v_gross*(100-v_agent_split)/100)*v_hst_rate/100)
    + (v_admin_fee*v_hst_rate/100)
    + coalesce(v_cheque_fees,0),2
  );
  IF v_gross<=0 OR v_amount<=0 THEN
    RAISE EXCEPTION 'Calculated brokerage share must be greater than zero.';
  END IF;

  v_reference := 'OUR-BROKERAGE:'||p_transaction_id::text;
  SELECT id INTO v_existing_id
  FROM public.dv_accounting_trust_transactions
  WHERE reference=v_reference AND trust_account_type='COMMISSION_TRUST'
    AND direction='DISBURSEMENT' AND status='POSTED'
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('already_posted',true,'amount',v_amount,'reference',v_reference);
  END IF;

  SELECT id INTO v_source_account_id
  FROM public.dv_accounting_bank_accounts
  WHERE company_id=v_company_id AND account_type='COMMISSION_TRUST' AND active IS TRUE
  ORDER BY created_at LIMIT 1;
  IF v_source_account_id IS NULL THEN
    RAISE EXCEPTION 'No active Commission Trust account was found.';
  END IF;

  SELECT d.client_name,d.matter INTO v_source_client,v_source_matter
  FROM public.dv_accounting_trust_transactions d
  WHERE d.transaction_id=p_transaction_id AND d.company_id=v_company_id
    AND d.trust_account_type='COMMISSION_TRUST' AND d.direction='DEPOSIT' AND d.status='POSTED'
  ORDER BY d.created_at DESC LIMIT 1;
  IF coalesce(trim(v_source_client),'')='' THEN
    RAISE EXCEPTION 'A posted Commission Trust deposit/client liability is required for this trade.';
  END IF;

  SELECT id INTO v_destination_account_id
  FROM public.dv_accounting_bank_accounts
  WHERE company_id=v_company_id AND account_type='OPERATING' AND active IS TRUE
  ORDER BY created_at LIMIT 1;
  IF v_destination_account_id IS NULL THEN
    RAISE EXCEPTION 'No active General Operating bank account was found.';
  END IF;

  PERFORM public.dv_accounting_post_trust_transaction(
    v_company_id,v_source_account_id,p_transaction_id,v_payment_date,
    'COMMISSION_TRUST','DISBURSEMENT',v_source_client,
    coalesce(nullif(v_source_matter,''),v_transaction_number),
    'Brokerage share transfer to General Operating - '||v_transaction_number,
    v_amount,v_reference
  );

  INSERT INTO public.dv_accounting_bank_transactions
    (bank_account_id,transaction_date,description,amount,reconciled,reference)
  SELECT v_destination_account_id,v_payment_date,
    'Brokerage share received from Commission Trust - '||v_transaction_number,
    v_amount,false,v_reference
  WHERE NOT EXISTS(
    SELECT 1 FROM public.dv_accounting_bank_transactions b
    WHERE b.reference=v_reference AND b.bank_account_id=v_destination_account_id
  );

  RETURN jsonb_build_object(
    'already_posted',false,'amount',v_amount,'reference',v_reference,
    'agent_split_percent',v_agent_split,'commission_before_hst',v_gross,
    'hst_rate',v_hst_rate,'agent_cheque_required',v_agent_split>0.0001
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_pay_our_brokerage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_pay_our_brokerage(uuid) TO authenticated;
