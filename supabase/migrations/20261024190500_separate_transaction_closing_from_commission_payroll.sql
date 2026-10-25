-- Closing a transaction must not implicitly make it ready for Commission Payroll.
-- The administrator sends it separately from the CLOSED transaction action menu.
CREATE OR REPLACE FUNCTION public.dv_accounting_close_transaction(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%rowtype;
  v_commission_id uuid;
  agent_amt numeric(14,2);
  gross_amt numeric(14,2);
  v_payroll_status text;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status<>'FINALIZED' THEN RAISE EXCEPTION 'Finalize the transaction accounting before closing it'; END IF;
  IF NOT coalesce(t.commission_approved,false) THEN RAISE EXCEPTION 'Commission amount must be approved before closing the transaction'; END IF;
  IF t.close_date IS NULL THEN RAISE EXCEPTION 'Close date is required before closing the transaction'; END IF;
  IF t.agent_id IS NULL THEN RAISE EXCEPTION 'Deal agent is required before closing the transaction'; END IF;

  gross_amt:=coalesce(t.commission_approved_amount,t.gross_commission,0);
  agent_amt:=coalesce(t.commission_approved_agent_payable,t.agent_commission,0);
  v_commission_id:=t.commission_id;

  IF v_commission_id IS NULL THEN
    SELECT id INTO v_commission_id FROM public.dv_accounting_commissions WHERE transaction_id=t.id ORDER BY id LIMIT 1;
    IF v_commission_id IS NULL THEN
      INSERT INTO public.dv_accounting_commissions(transaction_id,agent_id,gross_commission,brokerage_share,agent_share,status)
      VALUES(t.id,t.agent_id,gross_amt,greatest(gross_amt-agent_amt,0),agent_amt,'UNPAID')
      RETURNING id INTO v_commission_id;
    ELSE
      UPDATE public.dv_accounting_commissions
      SET status=CASE WHEN upper(coalesce(status,''))='PAID' THEN status ELSE 'UNPAID' END,
          agent_id=t.agent_id,gross_commission=gross_amt,
          brokerage_share=greatest(gross_amt-agent_amt,0),agent_share=agent_amt
      WHERE id=v_commission_id;
    END IF;
  ELSE
    UPDATE public.dv_accounting_commissions
    SET status=CASE WHEN upper(coalesce(status,''))='PAID' THEN status ELSE 'UNPAID' END,
        agent_id=t.agent_id,gross_commission=gross_amt,
        brokerage_share=greatest(gross_amt-agent_amt,0),agent_share=agent_amt
    WHERE id=v_commission_id;
  END IF;

  v_payroll_status := CASE WHEN EXISTS (
    SELECT 1 FROM public.dv_accounting_commission_cheques ch
    WHERE ch.commission_id=v_commission_id AND ch.status='ISSUED'
  ) THEN 'PAID' ELSE 'NOT_READY' END;

  UPDATE public.dv_accounting_transactions
  SET status='CLOSED',closed_at=coalesce(closed_at,now()),closed_by=auth.uid(),
      commission_payroll_status=v_payroll_status,commission_id=v_commission_id
  WHERE id=t.id;

  IF coalesce(t.ar_payment_received,false)
     AND coalesce(t.ar_payment_amount,0)>0
     AND t.ar_payment_bank_account_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.dv_accounting_trust_transactions tt
       WHERE tt.transaction_id=t.id
         AND tt.trust_account_type='COMMISSION_TRUST'
         AND tt.direction='DEPOSIT'
         AND tt.description LIKE 'Commission AR receipt%'
     )
  THEN
    PERFORM public.dv_accounting_post_trust_transaction(
      t.company_id,t.ar_payment_bank_account_id,t.id,
      coalesce(t.ar_payment_received_date,current_date),
      'COMMISSION_TRUST','DEPOSIT',
      coalesce(nullif(t.client_name,''),t.transaction_number),
      t.transaction_number,'Commission AR receipt — '||t.transaction_number,
      t.ar_payment_amount,null
    );
  END IF;

  RETURN jsonb_build_object('ok',true,'transaction_id',t.id,'commission_id',v_commission_id,
    'commission_payroll_status',v_payroll_status,'agent_payable',agent_amt);
END
$function$;
