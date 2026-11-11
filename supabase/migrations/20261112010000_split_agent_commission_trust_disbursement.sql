-- Apply the $500 minimum brokerage share to non-lease commission calculations.
DO $migration$
DECLARE
  v_definition text;
  v_old text := '  agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);';
  v_new text := $replacement$
  IF t.transaction_type='LEASE' THEN
    agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);
  ELSE
    agent_share:=GREATEST(
      LEAST(
        ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2),
        GREATEST(ROUND(COALESCE(p_gross_commission,0)-500,2),0)
      ),
      0
    );
  END IF;$replacement$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date)'::regprocedure)
    INTO v_definition;
  IF position(v_old in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate commission agent-share calculation; migration stopped.';
  END IF;
  v_definition := replace(v_definition,v_old,v_new);
  v_definition := replace(
    v_definition,
    '''brokerage_share_percent'',100-split_pct,',
    '''brokerage_share_percent'',CASE WHEN COALESCE(p_gross_commission,0)>0 THEN ROUND((COALESCE(p_gross_commission,0)-agent_share)*100/COALESCE(p_gross_commission,0),4) ELSE 0 END,'
  );
  EXECUTE v_definition;
END
$migration$;

-- A single agent payment may be funded by more than one client/matter liability
-- on the same trade (for example, buyer funds plus solicitor-direct commission).
-- Split the trust disbursement across those actual available liabilities.
CREATE OR REPLACE FUNCTION public.dv_accounting_post_commission_cheque_to_trust()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_company_id uuid;
  v_bank_account_id uuid;
  v_transaction_id uuid;
  v_transaction_number text;
  v_reference text;
  v_existing_total numeric(14,2) := 0;
  v_available_total numeric(14,2) := 0;
  v_remaining numeric(14,2) := 0;
  v_part numeric(14,2) := 0;
  v_sequence integer := 0;
  v_pair record;
BEGIN
  IF upper(coalesce(NEW.status,'')) <> 'ISSUED' THEN
    RETURN NEW;
  END IF;

  SELECT t.company_id,t.id,t.transaction_number
    INTO v_company_id,v_transaction_id,v_transaction_number
  FROM public.dv_accounting_transactions t
  WHERE t.id=(SELECT c.transaction_id FROM public.dv_accounting_commissions c WHERE c.id=NEW.commission_id);

  IF v_company_id IS NULL OR v_transaction_id IS NULL THEN
    RAISE EXCEPTION 'Cannot issue commission payment: linked transaction/company was not found.';
  END IF;

  IF coalesce(NEW.net_amount,0)<=0 THEN
    RAISE EXCEPTION 'Cannot issue commission payment: cheque net amount must be greater than zero.';
  END IF;

  v_reference := 'COMMISSION-CHEQUE:'||NEW.id::text;

  -- Idempotency: an already-posted complete payout must never be posted twice.
  SELECT coalesce(sum(x.amount),0)
    INTO v_existing_total
  FROM public.dv_accounting_trust_transactions x
  WHERE x.company_id=v_company_id
    AND x.transaction_id=v_transaction_id
    AND x.trust_account_type='COMMISSION_TRUST'
    AND x.direction='DISBURSEMENT'
    AND x.status='POSTED'
    AND (x.reference=v_reference OR x.reference LIKE v_reference||':%');

  IF v_existing_total>0 THEN
    IF abs(v_existing_total-NEW.net_amount)>0.005 THEN
      RAISE EXCEPTION 'A partial Commission Trust payout already exists for this cheque. Reconcile the existing trust entries before retrying.';
    END IF;
    RETURN NEW;
  END IF;

  -- Confirm that the combined, trade-linked client liabilities cover the cheque.
  SELECT coalesce(sum(pair_balance),0)
    INTO v_available_total
  FROM (
    SELECT l.client_name,l.matter,
      sum(CASE WHEN l.direction='RECEIVABLE' THEN l.amount ELSE -l.amount END) AS pair_balance
    FROM public.dv_accounting_trust_liabilities l
    JOIN public.dv_accounting_trust_transactions tt ON tt.id=l.trust_transaction_id
    WHERE l.company_id=v_company_id
      AND l.transaction_id=v_transaction_id
      AND l.trust_account_type='COMMISSION_TRUST'
      AND tt.status='POSTED'
    GROUP BY l.client_name,l.matter
  ) balances
  WHERE pair_balance>0;

  IF v_available_total+0.005<NEW.net_amount THEN
    RAISE EXCEPTION 'Commission Trust funds are insufficient for this agent payment. Available across this trade: %, payment required: %.',
      round(v_available_total,2),round(NEW.net_amount,2);
  END IF;

  v_remaining := round(NEW.net_amount,2);

  FOR v_pair IN
    SELECT l.client_name,l.matter,
      sum(CASE WHEN l.direction='RECEIVABLE' THEN l.amount ELSE -l.amount END) AS available,
      (array_agg(tt.bank_account_id ORDER BY tt.created_at))[1] AS bank_account_id
    FROM public.dv_accounting_trust_liabilities l
    JOIN public.dv_accounting_trust_transactions tt ON tt.id=l.trust_transaction_id
    WHERE l.company_id=v_company_id
      AND l.transaction_id=v_transaction_id
      AND l.trust_account_type='COMMISSION_TRUST'
      AND tt.status='POSTED'
    GROUP BY l.client_name,l.matter
    HAVING sum(CASE WHEN l.direction='RECEIVABLE' THEN l.amount ELSE -l.amount END)>0
    ORDER BY min(tt.created_at),l.client_name,l.matter
  LOOP
    EXIT WHEN v_remaining<=0.005;

    v_part := least(v_remaining,round(v_pair.available,2));
    IF v_part<=0 THEN
      CONTINUE;
    END IF;

    v_sequence := v_sequence+1;

    PERFORM public.dv_accounting_post_trust_transaction(
      v_company_id,
      v_pair.bank_account_id,
      v_transaction_id,
      coalesce(NEW.cheque_date,current_date),
      'COMMISSION_TRUST',
      'DISBURSEMENT',
      v_pair.client_name,
      v_pair.matter,
      'Commission payment to agent '||coalesce(NEW.payment_reference,NEW.cheque_number,'')||' for '||v_transaction_number,
      v_part,
      CASE WHEN v_sequence=1 THEN v_reference ELSE v_reference||':'||v_sequence::text END
    );

    v_remaining := round(v_remaining-v_part,2);
  END LOOP;

  IF v_remaining>0.005 THEN
    RAISE EXCEPTION 'Commission Trust disbursement could not be fully allocated. Remaining amount: %.',v_remaining;
  END IF;

  RETURN NEW;
END;
$function$;
