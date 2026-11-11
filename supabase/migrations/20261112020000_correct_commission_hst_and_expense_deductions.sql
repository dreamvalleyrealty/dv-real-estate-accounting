-- Keep expense deductions separate from the agent's commission HST base.
-- HST is calculated on agent commission after transaction admin/lead fees.
-- Agent expenses (desk, recurring, add-on and general) are deducted after HST.
DO $migration$
DECLARE
  v_definition text;
  v_old_recurring text := $old$
 select coalesce(sum(amount),0) into recurring_fees
 from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='RECURRING_FEE'
   and status='OPEN' and applied_to_cheque_id is null;$old$;
  v_new_recurring text := $new$
 select coalesce(sum(amount + case when hst_applicable then coalesce(hst_amount,0) else 0 end),0) into recurring_fees
 from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='RECURRING_FEE'
   and status='OPEN' and applied_to_cheque_id is null;$new$;
  v_old_service text := $old$
 select coalesce(sum(amount),0) into service_fees
 from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='ADD_ON_SERVICE'
   and status='OPEN' and applied_to_cheque_id is null;$old$;
  v_new_service text := $new$
 select coalesce(sum(amount + case when hst_applicable then coalesce(hst_amount,0) else 0 end),0) into service_fees
 from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='ADD_ON_SERVICE'
   and status='OPEN' and applied_to_cheque_id is null;$new$;
  v_old_hst text := 'agent_hst := round(net_before_hst*agent_hst_rate/100,2);';
  v_new_hst text := 'agent_hst := round(greatest(agent_share-transaction_fees,0)*agent_hst_rate/100,2);';
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text,boolean)'::regprocedure)
    INTO v_definition;
  IF position(v_old_recurring in v_definition)>0 THEN
    v_definition := replace(v_definition,v_old_recurring,v_new_recurring);
  ELSIF position(v_new_recurring in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate recurring fee calculation.';
  END IF;
  IF position(v_old_service in v_definition)>0 THEN
    v_definition := replace(v_definition,v_old_service,v_new_service);
  ELSIF position(v_new_service in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate add-on service fee calculation.';
  END IF;
  IF position(v_old_hst in v_definition)>0 THEN
    v_definition := replace(v_definition,v_old_hst,v_new_hst);
  ELSIF position(v_new_hst in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate agent HST calculation.';
  END IF;
  EXECUTE v_definition;
END
$migration$;
