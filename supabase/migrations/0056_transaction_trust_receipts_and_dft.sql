-- 0056: transaction receipt routing, failed-deal refund controls, and idempotent trust posting.
ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS ar_payment_received boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ar_payment_received_date date,
  ADD COLUMN IF NOT EXISTS ar_payment_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ar_payment_bank_account_id uuid REFERENCES public.dv_accounting_bank_accounts(id),
  ADD COLUMN IF NOT EXISTS ar_payment_reference text,
  ADD COLUMN IF NOT EXISTS dft_at timestamptz,
  ADD COLUMN IF NOT EXISTS dft_by uuid,
  ADD COLUMN IF NOT EXISTS deposit_refunded boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deposit_refund_date date,
  ADD COLUMN IF NOT EXISTS deposit_refund_method text,
  ADD COLUMN IF NOT EXISTS deposit_refund_reference text,
  ADD COLUMN IF NOT EXISTS deposit_refund_authority text,
  ADD COLUMN IF NOT EXISTS deposit_refund_amount numeric(14,2) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_dv_transactions_ar_received
  ON public.dv_accounting_transactions(ar_payment_received, close_date);

-- Post recorded receipts to the matching trust ledger. Safe to retry: each transaction
-- can have at most one receipt per trust type through this workflow.
CREATE OR REPLACE FUNCTION public.dv_accounting_post_transaction_receipts(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  tr public.dv_accounting_transaction_trust%ROWTYPE;
  company uuid;
  bank_type text;
  agent_name text;
  gl_bank uuid;
  gl_ar uuid;
  je uuid;
  already_posted boolean;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  company := COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1));
  IF company IS NULL THEN RAISE EXCEPTION 'Create a company in Settings before posting transaction receipts'; END IF;

  SELECT * INTO tr FROM public.dv_accounting_transaction_trust
  WHERE transaction_id=t.id AND we_hold_deposit='YES' AND received='YES' AND amount>0
  ORDER BY created_at DESC LIMIT 1;

  -- Buyer/seller deposits are consumer funds and must remain in Real Estate Trust.
  IF FOUND THEN
    IF tr.trust_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'Select a Real Estate Trust bank account for the received deposit';
    END IF;
    SELECT account_type INTO bank_type FROM public.dv_accounting_bank_accounts
      WHERE id=tr.trust_bank_account_id AND active=true;
    IF bank_type IS DISTINCT FROM 'REAL_ESTATE_TRUST' THEN
      RAISE EXCEPTION 'The deposit bank account must be an active Real Estate Trust account';
    END IF;
    SELECT EXISTS(SELECT 1 FROM public.dv_accounting_trust_transactions
      WHERE transaction_id=t.id AND trust_account_type='REAL_ESTATE_TRUST'
        AND direction='DEPOSIT' AND status='POSTED') INTO already_posted;
    IF NOT already_posted THEN
      PERFORM public.dv_accounting_post_trust_transaction(
        company,tr.trust_bank_account_id,t.id,COALESCE(tr.deposit_date,t.close_date,CURRENT_DATE),
        'REAL_ESTATE_TRUST','DEPOSIT',COALESCE(NULLIF(tr.received_from,''),t.client_name),
        t.property_address,'Buyer deposit received into Real Estate Trust',
        tr.amount,COALESCE(NULLIF(tr.reference_number,''),t.transaction_number)
      );
    END IF;
  END IF;

  -- Brokerage commission AR receipts are routed separately to Commission Trust.
  IF COALESCE(t.ar_payment_received,false) THEN
    IF COALESCE(t.ar_payment_amount,0)<=0 THEN RAISE EXCEPTION 'Enter the actual AR payment amount received'; END IF;
    IF t.ar_payment_bank_account_id IS NULL THEN RAISE EXCEPTION 'Select an active Commission Trust account for the AR receipt'; END IF;
    SELECT account_type INTO bank_type FROM public.dv_accounting_bank_accounts
      WHERE id=t.ar_payment_bank_account_id AND active=true;
    IF bank_type IS DISTINCT FROM 'COMMISSION_TRUST' THEN
      RAISE EXCEPTION 'The AR receipt bank account must be an active Commission Trust account';
    END IF;
    SELECT EXISTS(SELECT 1 FROM public.dv_accounting_trust_transactions
      WHERE transaction_id=t.id AND trust_account_type='COMMISSION_TRUST'
        AND direction='DEPOSIT' AND status='POSTED') INTO already_posted;
    IF NOT already_posted THEN
      SELECT concat_ws(' ',a.first_name,a.last_name) INTO agent_name
      FROM public.dv_accounting_agents a WHERE a.id=t.agent_id;
      PERFORM public.dv_accounting_post_trust_transaction(
        company,t.ar_payment_bank_account_id,t.id,COALESCE(t.ar_payment_received_date,t.close_date,CURRENT_DATE),
        'COMMISSION_TRUST','DEPOSIT',COALESCE(NULLIF(agent_name,''),t.client_name),
        t.property_address,'Commission AR payment received into Commission Trust',
        t.ar_payment_amount,COALESCE(NULLIF(t.ar_payment_reference,''),t.transaction_number)
      );

      INSERT INTO public.dv_accounting_gl_accounts(company_id,code,name,account_type)
      VALUES(company,'1020','Commission Trust Bank','ASSET')
      ON CONFLICT(company_id,code) DO NOTHING;
      SELECT id INTO gl_bank FROM public.dv_accounting_gl_accounts WHERE company_id=company AND code='1020';
      SELECT id INTO gl_ar FROM public.dv_accounting_gl_accounts WHERE company_id=company AND code='1150';
      IF gl_ar IS NULL THEN
        INSERT INTO public.dv_accounting_gl_accounts(company_id,code,name,account_type)
        VALUES(company,'1150','Commission Receivable','ASSET')
        ON CONFLICT(company_id,code) DO NOTHING;
        SELECT id INTO gl_ar FROM public.dv_accounting_gl_accounts WHERE company_id=company AND code='1150';
      END IF;
      INSERT INTO public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
      VALUES(company,COALESCE(t.ar_payment_received_date,t.close_date,CURRENT_DATE),
        'COMMISSION_AR_RECEIPT',t.id,'Commission receivable received into Commission Trust')
      RETURNING id INTO je;
      INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      VALUES(je,gl_bank,t.ar_payment_amount,0),(je,gl_ar,0,t.ar_payment_amount);
    END IF;
  END IF;

  RETURN jsonb_build_object('ok',true,'real_estate_deposit_posted',FOUND,
    'commission_ar_received',COALESCE(t.ar_payment_received,false));
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_post_transaction_receipts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_post_transaction_receipts(uuid) TO authenticated;

-- Close the transaction only after required trust receipts have been validated and posted.
CREATE OR REPLACE FUNCTION public.dv_accounting_close_transaction(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  v_commission_id uuid;
  agent_amt numeric(14,2);
  gross_amt numeric(14,2);
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status<>'FINALIZED' THEN RAISE EXCEPTION 'Finalize the transaction accounting before closing it'; END IF;
  IF NOT COALESCE(t.commission_approved,false) THEN RAISE EXCEPTION 'Commission amount must be approved before closing the transaction'; END IF;
  IF t.close_date IS NULL THEN RAISE EXCEPTION 'Close date is required before closing the transaction'; END IF;
  IF t.agent_id IS NULL THEN RAISE EXCEPTION 'Deal agent is required before sending the commission to payroll'; END IF;

  -- This call runs in the same database transaction. If trust details are invalid,
  -- closing and payroll queueing are rolled back together.
  PERFORM public.dv_accounting_post_transaction_receipts(t.id);

  gross_amt:=COALESCE(t.commission_approved_amount,t.gross_commission,0);
  agent_amt:=COALESCE(t.commission_approved_agent_payable,t.agent_commission,0);
  v_commission_id:=t.commission_id;
  IF v_commission_id IS NULL THEN
    SELECT id INTO v_commission_id FROM public.dv_accounting_commissions
      WHERE transaction_id=t.id ORDER BY id LIMIT 1;
    IF v_commission_id IS NULL THEN
      INSERT INTO public.dv_accounting_commissions(transaction_id,agent_id,gross_commission,brokerage_share,agent_share,status)
      VALUES(t.id,t.agent_id,gross_amt,GREATEST(gross_amt-agent_amt,0),agent_amt,'UNPAID')
      RETURNING id INTO v_commission_id;
    ELSE
      UPDATE public.dv_accounting_commissions
      SET agent_id=t.agent_id,gross_commission=gross_amt,
          brokerage_share=GREATEST(gross_amt-agent_amt,0),agent_share=agent_amt
      WHERE id=v_commission_id;
    END IF;
  ELSE
    UPDATE public.dv_accounting_commissions
    SET status=CASE WHEN status='PAID' THEN status ELSE 'UNPAID' END,
        agent_id=t.agent_id,gross_commission=gross_amt,
        brokerage_share=GREATEST(gross_amt-agent_amt,0),agent_share=agent_amt
    WHERE id=v_commission_id;
  END IF;

  UPDATE public.dv_accounting_transactions
  SET status='CLOSED',closed_at=COALESCE(closed_at,now()),closed_by=auth.uid(),
      commission_payroll_status=CASE WHEN EXISTS(
        SELECT 1 FROM public.dv_accounting_commission_cheques ch
        WHERE ch.commission_id=v_commission_id AND ch.status='ISSUED'
      ) THEN 'PAID' ELSE 'READY' END,
      commission_id=v_commission_id,company_id=COALESCE(company_id,
        (SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1))
  WHERE id=t.id;
  RETURN jsonb_build_object('ok',true,'transaction_id',t.id,'commission_id',v_commission_id,
    'commission_payroll_status','READY','agent_payable',agent_amt);
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_close_transaction(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_close_transaction(uuid) TO authenticated;

-- A failed transaction can only refund a held buyer deposit after the brokerage confirms
-- documented written mutual authorization or a court order. The RPC prevents double refunds.
CREATE OR REPLACE FUNCTION public.dv_accounting_mark_transaction_dft(
  p_transaction_id uuid,
  p_refund_bank_account_id uuid,
  p_refund_date date,
  p_refund_method text,
  p_refund_reference text,
  p_authority_reference text,
  p_release_authorized boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  tr public.dv_accounting_transaction_trust%ROWTYPE;
  company uuid;
  buyer_name text;
  bank_type text;
  je uuid;
  gl_bank uuid;
  gl_liability uuid;
  line record;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF t.status='CLOSED' THEN RAISE EXCEPTION 'A closed transaction cannot be marked DFT; contact an administrator to correct the accounting'; END IF;
  IF t.status='DFT' THEN RAISE EXCEPTION 'This transaction is already marked DFT'; END IF;
  IF NOT COALESCE(p_release_authorized,false) OR NULLIF(trim(p_authority_reference),'') IS NULL THEN
    RAISE EXCEPTION 'Confirm written mutual release or court-order authority and enter its reference before refunding a deposit';
  END IF;
  IF p_refund_method NOT IN ('CHEQUE','EFT') THEN RAISE EXCEPTION 'Refund method must be CHEQUE or EFT'; END IF;

  SELECT * INTO tr FROM public.dv_accounting_transaction_trust
  WHERE transaction_id=t.id AND we_hold_deposit='YES' AND received='YES' AND amount>0
  ORDER BY created_at DESC LIMIT 1;

  IF FOUND THEN
    IF COALESCE(t.deposit_refunded,false) THEN RAISE EXCEPTION 'The deposit has already been refunded'; END IF;
    IF p_refund_bank_account_id IS NULL THEN RAISE EXCEPTION 'Select the Real Estate Trust account to issue the refund'; END IF;
    SELECT account_type INTO bank_type FROM public.dv_accounting_bank_accounts
      WHERE id=p_refund_bank_account_id AND active=true;
    IF bank_type IS DISTINCT FROM 'REAL_ESTATE_TRUST' THEN
      RAISE EXCEPTION 'Refunds of buyer deposits must be paid from an active Real Estate Trust account';
    END IF;
    IF tr.trust_bank_account_id IS DISTINCT FROM p_refund_bank_account_id THEN
      RAISE EXCEPTION 'Use the same Real Estate Trust account that holds the deposit';
    END IF;

    SELECT COALESCE(NULLIF(concat_ws(' ',p.first_name,p.last_name),''),NULLIF(p.company_name,'')) INTO buyer_name
    FROM public.dv_accounting_transaction_people p
    WHERE p.transaction_id=t.id AND p.person_type IN ('BUYER','TENANT')
    ORDER BY p.created_at LIMIT 1;
    buyer_name:=COALESCE(NULLIF(buyer_name,''),t.client_name,'Buyer');

    -- Ensure the original receipt exists in the trust ledger before releasing it.
    IF NOT EXISTS(SELECT 1 FROM public.dv_accounting_trust_transactions
      WHERE transaction_id=t.id AND trust_account_type='REAL_ESTATE_TRUST' AND direction='DEPOSIT' AND status='POSTED') THEN
      PERFORM public.dv_accounting_post_trust_transaction(
        COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1)),
        tr.trust_bank_account_id,t.id,COALESCE(tr.deposit_date,CURRENT_DATE),
        'REAL_ESTATE_TRUST','DEPOSIT',COALESCE(NULLIF(tr.received_from,''),buyer_name),
        t.property_address,'Buyer deposit received before deal fell through',tr.amount,
        COALESCE(NULLIF(tr.reference_number,''),t.transaction_number)
      );
    END IF;
    PERFORM public.dv_accounting_post_trust_transaction(
      COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1)),
      p_refund_bank_account_id,t.id,COALESCE(p_refund_date,CURRENT_DATE),
      'REAL_ESTATE_TRUST','DISBURSEMENT',COALESCE(NULLIF(tr.received_from,''),buyer_name),
      t.property_address,'DFT buyer deposit refund - '||p_refund_method,tr.amount,
      COALESCE(NULLIF(p_refund_reference,''),t.transaction_number)
    );

    -- Reverse any finalization journal entry for the failed deal (balanced counter-entry).
    IF EXISTS(SELECT 1 FROM public.dv_accounting_journal_entries WHERE source_type='TRANSACTION' AND source_id=t.id) THEN
      IF NOT EXISTS(SELECT 1 FROM public.dv_accounting_journal_entries WHERE source_type='DFT_REVERSAL' AND source_id=t.id) THEN
        INSERT INTO public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
        VALUES(COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1)),
          COALESCE(p_refund_date,CURRENT_DATE),'DFT_REVERSAL',t.id,'Reverse transaction accounting - deal fell through')
        RETURNING id INTO je;
        FOR line IN
          SELECT jl.gl_account_id,jl.debit,jl.credit
          FROM public.dv_accounting_journal_lines jl
          JOIN public.dv_accounting_journal_entries oldje ON oldje.id=jl.journal_entry_id
          WHERE oldje.source_type='TRANSACTION' AND oldje.source_id=t.id
        LOOP
          INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
          VALUES(je,line.gl_account_id,line.credit,line.debit);
        END LOOP;
      END IF;
    END IF;

    UPDATE public.dv_accounting_transactions
    SET status='DFT',dft_at=now(),dft_by=auth.uid(),deposit_refunded=true,
        deposit_refund_date=COALESCE(p_refund_date,CURRENT_DATE),
        deposit_refund_method=p_refund_method,deposit_refund_reference=p_refund_reference,
        deposit_refund_authority=p_authority_reference,deposit_refund_amount=tr.amount,
        commission_payroll_status='NOT_READY'
    WHERE id=t.id;
  ELSE
    UPDATE public.dv_accounting_transactions
    SET status='DFT',dft_at=now(),dft_by=auth.uid(),commission_payroll_status='NOT_READY'
    WHERE id=t.id;
  END IF;

  RETURN jsonb_build_object('ok',true,'transaction_id',t.id,'status','DFT',
    'deposit_refunded',FOUND,'refund_amount',COALESCE(tr.amount,0));
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
