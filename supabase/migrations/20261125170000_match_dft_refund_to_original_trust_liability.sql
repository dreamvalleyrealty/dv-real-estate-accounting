-- Use the original posted deposit liability's exact client/matter key when refunding.
-- This prevents a valid deposit from appearing unavailable because a refund routine
-- substituted the property's address for the original matter reference.
CREATE OR REPLACE FUNCTION public.dv_accounting_mark_transaction_dft_internal(
  p_transaction_id uuid,
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
  company uuid;
  buyer_name text;
  trust_client_name text;
  trust_matter text;
  bank_type text;
  je uuid;
  gl_bank uuid;
  gl_liability uuid;
  line record;
  refund_done boolean := false;
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

    -- Reuse the exact client/matter key that owns the original posted receipt.
    SELECT l.client_name,l.matter INTO trust_client_name,trust_matter
    FROM public.dv_accounting_trust_liabilities l
    JOIN public.dv_accounting_trust_transactions tt ON tt.id=l.trust_transaction_id
    WHERE tt.transaction_id=t.id
      AND tt.trust_account_type='REAL_ESTATE_TRUST'
      AND tt.direction='DEPOSIT' AND tt.status='POSTED'
      AND l.direction='RECEIVABLE'
    ORDER BY l.created_at ASC
    LIMIT 1;

    trust_client_name:=COALESCE(NULLIF(trust_client_name,''),NULLIF(tr.received_from,''),buyer_name);
    trust_matter:=COALESCE(NULLIF(trust_matter,''),NULLIF(t.transaction_number,''),t.property_address);

    -- Ensure the original receipt exists in the trust ledger before releasing it.
    IF NOT EXISTS(SELECT 1 FROM public.dv_accounting_trust_transactions
      WHERE transaction_id=t.id AND trust_account_type='REAL_ESTATE_TRUST' AND direction='DEPOSIT' AND status='POSTED') THEN
      PERFORM public.dv_accounting_post_trust_transaction(
        COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1)),
        tr.trust_bank_account_id,t.id,COALESCE(tr.deposit_date,CURRENT_DATE),
        'REAL_ESTATE_TRUST','DEPOSIT',trust_client_name,
        trust_matter,'Buyer deposit received before deal fell through',tr.amount,
        COALESCE(NULLIF(tr.reference_number,''),t.transaction_number)
      );
    END IF;
    PERFORM public.dv_accounting_post_trust_transaction(
      COALESCE(t.company_id,(SELECT id FROM public.dv_accounting_companies ORDER BY created_at LIMIT 1)),
      p_refund_bank_account_id,t.id,COALESCE(p_refund_date,CURRENT_DATE),
      'REAL_ESTATE_TRUST','DISBURSEMENT',trust_client_name,
      trust_matter,'DFT buyer deposit refund - '||p_refund_method,tr.amount,
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

    refund_done := true;
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
    'deposit_refunded',refund_done,'refund_amount',CASE WHEN refund_done THEN COALESCE(tr.amount,0) ELSE 0 END);
END
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft_internal(uuid,uuid,date,text,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_mark_transaction_dft_internal(uuid,uuid,date,text,text,text,boolean) TO authenticated,service_role;
