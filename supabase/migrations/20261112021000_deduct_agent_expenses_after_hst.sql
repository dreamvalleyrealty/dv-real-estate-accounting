-- Keep agent expenses deductible after commission HST is calculated.
-- HST applies to agent share after transaction admin/lead fees; recurring,
-- service, desk and general expenses are then deducted from the payout.
DO $migration$
DECLARE
  v_definition text;
  v_old_return text := $old$'net_amount',net_before_hst+coalesce(p_adjustment,0)+agent_hst,$old$;
  v_new_return text := $new$'net_amount',greatest(round(agent_share-transaction_fees,2),0)+agent_hst-recurring_fees-service_fees-desk_fees-general_fees+coalesce(p_adjustment,0),$new$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text,boolean)'::regprocedure)
    INTO v_definition;
  IF position(v_old_return in v_definition)>0 THEN
    v_definition:=replace(v_definition,v_old_return,v_new_return);
  ELSIF position(v_new_return in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate commission payment net amount expression.';
  END IF;
  EXECUTE v_definition;
END
$migration$;
