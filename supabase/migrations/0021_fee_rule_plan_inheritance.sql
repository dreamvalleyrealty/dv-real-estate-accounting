-- 0021: fee-rule inheritance from assigned fee plan
create or replace function public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 90;
  desk_fee numeric := 0;
  admin_type text := 'AMOUNT';
  admin_value numeric := 0;
  lead_type text := 'AMOUNT';
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
begin
  select * into t from public.dv_accounting_transactions where id=p_transaction_id;
  if not found then raise exception 'Transaction not found'; end if;

  select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
  if fs.fee_plan_id is not null then
    select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
  end if;

  select * into rule
  from public.dv_accounting_agent_fee_rules
  where agent_id=p_agent_id and active
    and effective_from<=p_as_of
    and (effective_to is null or effective_to>=p_as_of)
  order by effective_from desc,created_at desc limit 1;

  split_pct:=coalesce(
    rule.commission_split_percent,
    fs.commission_split_override_percent,
    plan.commission_split_percent,
    90
  );
  desk_fee:=coalesce(
    rule.desk_fee,
    fs.desk_fee_override,
    plan.desk_fee,
    0
  );

  if t.market_segment='COMMERCIAL' and t.side='LEASE' then
    admin_type:=coalesce(rule.admin_fee_commercial_lease_type,fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_commercial_lease_value,fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
  elsif t.market_segment='COMMERCIAL' then
    admin_type:=coalesce(rule.admin_fee_commercial_buy_sell_type,fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_commercial_buy_sell_value,fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
  elsif t.side='LEASE' then
    admin_type:=coalesce(rule.admin_fee_lease_type,fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_lease_value,fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
  else
    admin_type:=coalesce(rule.admin_fee_buy_sell_type,fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_buy_sell_value,fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
  end if;

  if t.side='LEASE' then
    lead_type:=coalesce(rule.lead_fee_lease_type,fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
    lead_value:=coalesce(rule.lead_fee_lease_value,fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
  else
    lead_type:=coalesce(rule.lead_fee_buy_sell_type,fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
    lead_value:=coalesce(rule.lead_fee_buy_sell_value,fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
  end if;

  agent_share:=round(coalesce(p_gross_commission,0)*split_pct/100,2);
  if admin_type='PERCENT' then admin_fee:=round(coalesce(p_gross_commission,0)*admin_value/100,2); else admin_fee:=round(admin_value,2); end if;
  if lead_type='PERCENT' then lead_fee:=round(coalesce(p_gross_commission,0)*lead_value/100,2); else lead_fee:=round(lead_value,2); end if;

  return jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'total_transaction_fees',round(admin_fee+lead_fee,2),
    'net_transaction_commission',round(agent_share-admin_fee-lead_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
end $$;

grant execute on function public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) to authenticated;
