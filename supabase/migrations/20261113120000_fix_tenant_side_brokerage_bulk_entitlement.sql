-- Bulk brokerage transfers must pay the recorded brokerage entitlement, not sweep
-- every remaining Commission Trust dollar. This is important for tenant-side trades:
-- the transaction's BUYER-side commission is Dream Valley's represented side.
DO $migration$
DECLARE
  v_definition text;
  v_old_select text := 'select c.id commission_id,c.transaction_id,c.status commission_status,t.company_id,t.transaction_number,t.status transaction_status,';
  v_new_select text := 'select c.id commission_id,c.transaction_id,c.status commission_status,c.brokerage_share,t.company_id,t.transaction_number,t.status transaction_status,';
  v_old_balance text := $old$
  select round(coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0),2) into v_item_amount
  from public.dv_accounting_trust_liabilities l where l.company_id=v_commission.company_id and l.transaction_id=v_commission.transaction_id and l.trust_account_type='COMMISSION_TRUST';
  $old$;
  v_new_balance text := $new$
  v_brokerage_hst:=round(coalesce(v_commission.brokerage_hst_amount,0),2);
  v_brokerage_amount:=round(coalesce(v_commission.brokerage_share,0),2);
  v_item_amount:=round(v_brokerage_amount+v_brokerage_hst,2);
  $new$;
  v_old_hst text := '  v_brokerage_hst:=round(coalesce(v_commission.brokerage_hst_amount,0),2);';
  v_old_brokerage text := '  v_brokerage_amount:=round(v_item_amount-v_brokerage_hst,2);';
  v_new_brokerage text := '  v_brokerage_amount:=round(coalesce(v_commission.brokerage_share,0),2);';
  v_old_liability text := 'and coalesce(l.matter,'''')=coalesce(v_commission.matter,'''');';
  v_new_liability text := 'and coalesce(l.matter,'''')=coalesce(v_commission.matter,'''') and l.transaction_id=v_commission.transaction_id;';
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date)'::regprocedure)
    INTO v_definition;
  IF position(v_new_select in v_definition)=0 THEN
    IF position(v_old_select in v_definition)=0 THEN RAISE EXCEPTION 'Could not locate brokerage bulk commission query.'; END IF;
    v_definition:=replace(v_definition,v_old_select,v_new_select);
  END IF;
  IF position(v_new_balance in v_definition)=0 THEN
    IF position(v_old_balance in v_definition)=0 THEN RAISE EXCEPTION 'Could not locate brokerage bulk balance calculation.'; END IF;
    v_definition:=replace(v_definition,v_old_balance,v_new_balance);
  END IF;
  IF position(v_old_brokerage in v_definition)>0 THEN
    v_definition:=replace(v_definition,v_old_brokerage,v_new_brokerage);
  END IF;
  IF position(v_old_liability in v_definition)>0 THEN
    v_definition:=replace(v_definition,v_old_liability,v_new_liability);
  END IF;
  EXECUTE v_definition;
END
$migration$;
