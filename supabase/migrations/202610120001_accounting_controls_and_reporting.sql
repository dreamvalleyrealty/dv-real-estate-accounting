-- 2026-10-12: accounting controls, GL reporting views, and recurring-fee safeguards
-- Apply this migration in Supabase SQL Editor after the existing migrations.

create extension if not exists pgcrypto;

-- Zero-value charges are not valid receivables; retain existing history but stop future generation.
alter table public.dv_accounting_commission_charges
  add column if not exists source_subscription_id uuid,
  add column if not exists service_period_start date,
  add column if not exists service_period_end date;

create unique index if not exists dv_accounting_commission_charge_subscription_period_uq
  on public.dv_accounting_commission_charges(source_subscription_id, service_period_start)
  where source_subscription_id is not null;

-- Correct stale desk-fee subscriptions against the agent's currently assigned fee plan.
-- A zero desk fee on the plan means no desk fee, even if an old subscription exists.
create or replace function public.dv_accounting_sync_agent_desk_fee_subscription(
  p_agent_id uuid,
  p_start_date date default current_date
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  a public.dv_accounting_agents%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  sub public.dv_accounting_agent_service_subscriptions%rowtype;
  sid uuid;
  fee numeric(14,2);
  freq text;
begin
  select * into a from public.dv_accounting_agents where id=p_agent_id;
  if not found then raise exception 'Agent not found'; end if;

  select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
  if fs.fee_plan_id is not null then
    select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
  end if;

  fee:=greatest(0,coalesce(fs.desk_fee_override,plan.desk_fee,0));
  freq:=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,'MONTHLY');

  select * into sub
  from public.dv_accounting_agent_service_subscriptions
  where agent_id=p_agent_id and service_type='DESK_FEE' and active
  order by created_at desc limit 1
  for update;

  if fee<=0 then
    update public.dv_accounting_agent_service_subscriptions
       set active=false, end_date=coalesce(end_date,p_start_date - 1)
     where agent_id=p_agent_id and service_type='DESK_FEE' and active;
    return null;
  end if;

  if sub.id is not null then
    update public.dv_accounting_agent_service_subscriptions
       set amount=fee, frequency=freq
     where id=sub.id;
    return sub.id;
  end if;

  insert into public.dv_accounting_agent_service_subscriptions(
    company_id,agent_id,service_type,name,amount,hst_amount,frequency,
    start_date,next_charge_date,active,notes
  ) values (
    a.company_id,a.id,'DESK_FEE','Desk Fee',fee,0,freq,
    p_start_date,p_start_date,true,'Synced from current assigned fee plan'
  ) returning id into sid;
  return sid;
end $$;

create or replace function public.dv_accounting_run_agent_service_billing(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  s public.dv_accounting_agent_service_subscriptions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  next_date date;
  created_count integer:=0;
  skipped_count integer:=0;
  amount_due numeric(14,2);
  period_start date;
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
      amount_due:=greatest(0,coalesce(fs.desk_fee_override,plan.desk_fee,0));
      if amount_due<=0 then
        update public.dv_accounting_agent_service_subscriptions
           set active=false,end_date=coalesce(end_date,p_run_date-1)
         where id=s.id;
        skipped_count:=skipped_count+1;
        continue;
      end if;
      update public.dv_accounting_agent_service_subscriptions
         set amount=amount_due,frequency=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,s.frequency)
       where id=s.id;
    end if;

    if amount_due<=0 then
      skipped_count:=skipped_count+1;
    else
      period_start:=s.next_charge_date;
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount,status,
        source_subscription_id,service_period_start,service_period_end
      ) values (
        null,null,s.agent_id,
        case when s.service_type='DESK_FEE' then 'DESK_FEE' else 'ADD_ON_SERVICE' end,
        s.name,amount_due,'OPEN',s.id,period_start,
        case when s.frequency='MONTHLY' then (period_start+interval '1 month - 1 day')::date
             when s.frequency='QUARTERLY' then (period_start+interval '3 months - 1 day')::date
             when s.frequency='SEMI_ANNUALLY' then (period_start+interval '6 months - 1 day')::date
             else (period_start+interval '1 year - 1 day')::date end
      ) on conflict (source_subscription_id,service_period_start)
        where source_subscription_id is not null do nothing;
      if found then created_count:=created_count+1; end if;
    end if;

    next_date:=case
      when s.frequency='MONTHLY' then (s.next_charge_date+interval '1 month')::date
      when s.frequency='QUARTERLY' then (s.next_charge_date+interval '3 months')::date
      when s.frequency='SEMI_ANNUALLY' then (s.next_charge_date+interval '6 months')::date
      when s.frequency='ANNUALLY' then (s.next_charge_date+interval '1 year')::date
      else s.next_charge_date+interval '1 month'
    end;
    update public.dv_accounting_agent_service_subscriptions
       set next_charge_date=next_date,
           active=case when end_date is not null and next_date>end_date then false else active end
     where id=s.id;
  end loop;
  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count);
end $$;

create or replace function public.dv_accounting_run_recurring_fees(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  r public.dv_accounting_recurring_fee_rules%rowtype;
  created_count integer:=0;
  skipped_count integer:=0;
  next_date date;
begin
  for r in
    select * from public.dv_accounting_recurring_fee_rules
    where active and next_run_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_run_date,created_at
    for update
  loop
    if coalesce(r.amount,0)<=0 then
      skipped_count:=skipped_count+1;
    elsif r.applies_to='BROKERAGE' then
      insert into public.dv_accounting_expenses(
        company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status
      ) values(r.company_id,p_run_date,'Recurring',coalesce(r.category,'RECURRING'),
        coalesce(r.description,r.name),r.amount,greatest(0,coalesce(r.hst_amount,0)),'OPEN','UNPAID');
      created_count:=created_count+1;
    else
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount,status
      ) values(null,null,r.agent_id,'RECURRING_FEE',coalesce(r.description,r.name),r.amount,'OPEN');
      created_count:=created_count+1;
    end if;
    next_date:=case
      when r.frequency='MONTHLY' then (r.next_run_date+interval '1 month')::date
      when r.frequency='QUARTERLY' then (r.next_run_date+interval '3 months')::date
      when r.frequency='SEMI_ANNUALLY' then (r.next_run_date+interval '6 months')::date
      when r.frequency='ANNUALLY' then (r.next_run_date+interval '1 year')::date
      else r.next_run_date+greatest(coalesce(r.interval_days,30),1)
    end;
    update public.dv_accounting_recurring_fee_rules
       set next_run_date=next_date,
           active=case when end_date is not null and next_date>end_date then false else active end
     where id=r.id;
  end loop;
  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count);
end $$;

-- Seed the minimum Canadian brokerage chart of accounts for new and existing companies.
insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
select c.id,a.code,a.name,a.account_type
from public.dv_accounting_companies c
cross join (values
 ('1000','Operating Bank','ASSET'),
 ('1010','Real Estate Trust Bank','ASSET'),
 ('1020','Commission Trust Bank','ASSET'),
 ('1100','Accounts Receivable','ASSET'),
 ('1150','Commission Receivable','ASSET'),
 ('1200','HST Recoverable / ITCs','ASSET'),
 ('1500','Capital Assets','ASSET'),
 ('1590','Accumulated Depreciation','ASSET'),
 ('2000','Accounts Payable','LIABILITY'),
 ('2100','Payroll Liabilities','LIABILITY'),
 ('2200','Agent Commissions Payable','LIABILITY'),
 ('2300','Real Estate Trust Liabilities','LIABILITY'),
 ('2310','Commission Trust Liabilities','LIABILITY'),
 ('2400','HST Payable','LIABILITY'),
 ('3000','Owner Equity','EQUITY'),
 ('3100','Retained Earnings','EQUITY'),
 ('4000','Commission Revenue','REVENUE'),
 ('4100','Other Revenue','REVENUE'),
 ('5000','Operating Expenses','EXPENSE'),
 ('5100','Payroll Expense','EXPENSE'),
 ('5200','Agent Commission Expense','EXPENSE'),
 ('5300','Rent and Occupancy','EXPENSE'),
 ('5400','Marketing and Advertising','EXPENSE'),
 ('5500','Professional Fees','EXPENSE'),
 ('5600','Bank Charges','EXPENSE'),
 ('5700','Depreciation Expense','EXPENSE')
) as a(code,name,account_type)
on conflict(company_id,code) do nothing;

-- Read-only financial report views based exclusively on posted journal lines.
create or replace view public.dv_accounting_v_general_ledger as
select je.company_id,je.id as journal_entry_id,je.entry_date,je.source_type,je.source_id,je.memo,
       ga.id as gl_account_id,ga.code as account_code,ga.name as account_name,ga.account_type,
       jl.id as journal_line_id,jl.debit,jl.credit,(jl.debit-jl.credit) as net_amount
from public.dv_accounting_journal_entries je
join public.dv_accounting_journal_lines jl on jl.journal_entry_id=je.id
join public.dv_accounting_gl_accounts ga on ga.id=jl.gl_account_id;

create or replace view public.dv_accounting_v_trial_balance as
select company_id,gl_account_id,account_code,account_name,account_type,
       sum(debit) as total_debits,sum(credit) as total_credits,
       sum(debit-credit) as debit_balance_signed,
       case when sum(debit-credit)>0 then sum(debit-credit) else 0 end as debit_balance,
       case when sum(debit-credit)<0 then abs(sum(debit-credit)) else 0 end as credit_balance
from public.dv_accounting_v_general_ledger
group by company_id,gl_account_id,account_code,account_name,account_type;

create or replace view public.dv_accounting_v_profit_loss as
select company_id,account_code,account_name,account_type,
       sum(case when account_type='REVENUE' then credit-debit else debit-credit end) as amount
from public.dv_accounting_v_general_ledger
where account_type in ('REVENUE','EXPENSE')
group by company_id,account_code,account_name,account_type;

create or replace view public.dv_accounting_v_balance_sheet as
select company_id,account_code,account_name,account_type,
       sum(case when account_type in ('LIABILITY','EQUITY') then credit-debit else debit-credit end) as balance
from public.dv_accounting_v_general_ledger
where account_type in ('ASSET','LIABILITY','EQUITY')
group by company_id,account_code,account_name,account_type;

-- Journal integrity check. The application should post a complete entry in one transaction.
create or replace function public.dv_accounting_check_journal_entry(p_entry_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare d numeric(14,2); c numeric(14,2); n integer;
begin
  select coalesce(sum(debit),0),coalesce(sum(credit),0),count(*)
    into d,c,n from public.dv_accounting_journal_lines where journal_entry_id=p_entry_id;
  return jsonb_build_object('journal_entry_id',p_entry_id,'line_count',n,'debits',d,'credits',c,
    'balanced',n>=2 and round(d,2)=round(c,2));
end $$;

grant execute on function public.dv_accounting_check_journal_entry(uuid) to authenticated;
grant select on public.dv_accounting_v_general_ledger,public.dv_accounting_v_trial_balance,
  public.dv_accounting_v_profit_loss,public.dv_accounting_v_balance_sheet to authenticated;

-- Seed missing subscription corrections for all agents; zero-fee plans are deactivated.
do $$
declare a record;
begin
  for a in select id from public.dv_accounting_agents loop
    perform public.dv_accounting_sync_agent_desk_fee_subscription(a.id,current_date);
  end loop;
end $$;
