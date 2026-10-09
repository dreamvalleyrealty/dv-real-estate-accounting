-- 0019: recurring fee idempotency and commission cheque application of outstanding agent recurring charges

alter table public.dv_accounting_commission_charges
  add column if not exists applied_to_cheque_id uuid references public.dv_accounting_commission_cheques(id),
  add column if not exists status text not null default 'OPEN'
    check(status in ('OPEN','APPLIED','VOID'));

create index if not exists idx_dv_commission_charges_agent_open
  on public.dv_accounting_commission_charges(agent_id,status,charge_type);

create or replace function public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text default null,
  p_cheque_date date default current_date,
  p_adjustment numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  transaction_fees numeric(14,2);
  recurring_fees numeric(14,2);
  total_fees numeric(14,2);
  agent_share numeric(14,2);
begin
  select * into c from public.dv_accounting_commissions where id=p_commission_id for update;
  if not found then raise exception 'Commission record not found'; end if;
  if c.status='PAID' then raise exception 'Commission has already been paid'; end if;
  select * into t from public.dv_accounting_transactions where id=c.transaction_id;
  select * into agent from public.dv_accounting_agents where id=c.agent_id;
  if not found then raise exception 'Agent not found'; end if;

  calc:=public.dv_accounting_calculate_commission_fees(
    c.agent_id,c.transaction_id,coalesce(c.gross_commission,t.gross_commission,0),coalesce(t.transaction_date,p_cheque_date)
  );
  agent_share:=coalesce((calc->>'agent_share')::numeric,0);
  transaction_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);

  select coalesce(sum(amount),0) into recurring_fees
  from public.dv_accounting_commission_charges
  where agent_id=c.agent_id
    and charge_type='RECURRING_FEE'
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  total_fees:=transaction_fees+recurring_fees;

  insert into public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,
    agent_share,total_fees,adjustments,status,issued_at,notes
  )
  values(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,
    coalesce(c.gross_commission,t.gross_commission,0),agent_share,total_fees,
    coalesce(p_adjustment,0),'ISSUED',now(),p_notes
  ) returning id into cheque_id;

  insert into public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,
    source_rule_id,status,applied_to_cheque_id
  )
  select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end,
         'APPLIED',cheque_id
  from jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
    )
  ) as x(charge_type text,description text,amount numeric)
  where x.amount<>0;

  update public.dv_accounting_commission_charges
  set status='APPLIED',applied_to_cheque_id=cheque_id
  where agent_id=c.agent_id
    and charge_type='RECURRING_FEE'
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  update public.dv_accounting_commissions
  set status='PAID',paid_date=p_cheque_date
  where id=c.id;

  return jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'transaction_fees',transaction_fees,
    'recurring_fees',recurring_fees,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),
    'calculation',calc
  );
end $$;

grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) to authenticated;

create or replace function public.dv_accounting_run_recurring_fees(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  r public.dv_accounting_recurring_fee_rules%rowtype;
  created_count integer := 0;
  skipped_count integer := 0;
  run_id uuid;
begin
  if exists(select 1 from public.dv_accounting_recurring_fee_runs where run_date=p_run_date) then
    return jsonb_build_object('run_date',p_run_date,'created_count',0,'skipped_count',1,'status','ALREADY_RUN');
  end if;

  insert into public.dv_accounting_recurring_fee_runs(company_id,run_date,status)
  select id,p_run_date,'POSTED'
  from public.dv_accounting_companies
  order by created_at
  limit 1
  returning id into run_id;

  if run_id is null then raise exception 'Create a company before running recurring fees'; end if;

  for r in
    select * from public.dv_accounting_recurring_fee_rules
    where active and next_run_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_run_date,created_at
  loop
    if r.applies_to='BROKERAGE' then
      insert into public.dv_accounting_expenses(company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status)
      values(r.company_id,p_run_date,'Recurring','RECURRING',r.description,r.amount,r.hst_amount,'OPEN','UNPAID');
    else
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount,status
      )
      values(null,null,r.agent_id,'RECURRING_FEE',coalesce(r.description,r.name),r.amount,'OPEN');
    end if;
    created_count:=created_count+1;

    update public.dv_accounting_recurring_fee_rules
    set next_run_date=
      case
        when frequency='MONTHLY' then (next_run_date + interval '1 month')::date
        when frequency='QUARTERLY' then (next_run_date + interval '3 months')::date
        when frequency='SEMI_ANNUALLY' then (next_run_date + interval '6 months')::date
        when frequency='ANNUALLY' then (next_run_date + interval '1 year')::date
        when frequency='CUSTOM_DAYS' then next_run_date + greatest(coalesce(interval_days,30),1)
      end
    where id=r.id;
  end loop;

  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count,'run_id',run_id);
end $$;

grant execute on function public.dv_accounting_run_recurring_fees(date) to authenticated;
