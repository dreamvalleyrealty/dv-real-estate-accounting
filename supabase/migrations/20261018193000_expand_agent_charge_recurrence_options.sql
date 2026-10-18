ALTER TABLE public.dv_accounting_agent_service_subscriptions
  DROP CONSTRAINT IF EXISTS dv_accounting_agent_service_subscriptions_frequency_check;
ALTER TABLE public.dv_accounting_agent_service_subscriptions
  ADD CONSTRAINT dv_accounting_agent_service_subscriptions_frequency_check
  CHECK (frequency = ANY (ARRAY['WEEKLY','BIWEEKLY','MONTHLY','BIMONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY']::text[]));

CREATE OR REPLACE FUNCTION public.dv_accounting_run_agent_service_billing(p_run_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s public.dv_accounting_agent_service_subscriptions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  next_date date;
  created_count integer:=0;
  skipped_count integer:=0;
  amount_due numeric(14,2);
  period_start date;
  period_end date;
begin
  for s in
    select * from public.dv_accounting_agent_service_subscriptions
    where active and next_charge_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_charge_date,created_at
    for update
  loop
    amount_due:=greatest(0,coalesce(s.amount,0));
    if s.service_type='DESK_FEE' then
      select * into fs from public.dv_accounting_agent_fee_settings where agent_id=s.agent_id;
      if fs.fee_plan_id is not null then
        select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
      else
        plan:=null;
      end if;
      amount_due:=case when plan.id is not null and coalesce(plan.desk_fee,0)<=0 then 0 else greatest(0,coalesce(fs.desk_fee_override,plan.desk_fee,0)) end;
      if amount_due<=0 then
        update public.dv_accounting_agent_service_subscriptions set active=false,end_date=coalesce(end_date,p_run_date-1) where id=s.id;
        skipped_count:=skipped_count+1;
        continue;
      end if;
      update public.dv_accounting_agent_service_subscriptions set amount=amount_due,frequency=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,s.frequency) where id=s.id;
      s.frequency:=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,s.frequency);
    end if;
    if amount_due<=0 then
      skipped_count:=skipped_count+1;
    else
      period_start:=s.next_charge_date;
      period_end:=case
        when s.frequency='WEEKLY' then period_start+6
        when s.frequency='BIWEEKLY' then period_start+13
        when s.frequency='MONTHLY' then (period_start+interval '1 month - 1 day')::date
        when s.frequency='BIMONTHLY' then (period_start+interval '2 months - 1 day')::date
        when s.frequency='QUARTERLY' then (period_start+interval '3 months - 1 day')::date
        when s.frequency='SEMI_ANNUALLY' then (period_start+interval '6 months - 1 day')::date
        else (period_start+interval '1 year - 1 day')::date
      end;
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount,status,
        source_subscription_id,service_period_start,service_period_end,hst_applicable,base_amount,hst_amount
      ) values (
        null,null,s.agent_id,
        case when s.service_type='DESK_FEE' then 'DESK_FEE' else 'ADD_ON_SERVICE' end,
        s.name,amount_due,'OPEN',s.id,period_start,period_end,
        coalesce(s.hst_applicable,false),amount_due,
        case when coalesce(s.hst_applicable,false) then round(amount_due*0.13,2) else 0 end
      ) on conflict (source_subscription_id,service_period_start) where source_subscription_id is not null do nothing;
      if found then created_count:=created_count+1; end if;
    end if;
    next_date:=case
      when s.frequency='WEEKLY' then s.next_charge_date+7
      when s.frequency='BIWEEKLY' then s.next_charge_date+14
      when s.frequency='MONTHLY' then (s.next_charge_date+interval '1 month')::date
      when s.frequency='BIMONTHLY' then (s.next_charge_date+interval '2 months')::date
      when s.frequency='QUARTERLY' then (s.next_charge_date+interval '3 months')::date
      when s.frequency='SEMI_ANNUALLY' then (s.next_charge_date+interval '6 months')::date
      else (s.next_charge_date+interval '1 year')::date
    end;
    update public.dv_accounting_agent_service_subscriptions
       set next_charge_date=next_date,
           active=case when end_date is not null and next_date>end_date then false else active end
     where id=s.id;
  end loop;
  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count);
end $function$;
