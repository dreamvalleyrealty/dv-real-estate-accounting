-- 0018: fee rules, effective-date promotions, commission charges/cheques and recurring fees

alter table public.dv_accounting_transactions
  add column if not exists market_segment text not null default 'RESIDENTIAL'
    check (market_segment in ('RESIDENTIAL','COMMERCIAL'));

alter table public.dv_accounting_fee_plans
  add column if not exists admin_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_lease_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_lease_value numeric(14,4) not null default 0;

alter table public.dv_accounting_agent_fee_settings
  add column if not exists admin_fee_buy_sell_type text,
  add column if not exists admin_fee_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_lease_type text,
  add column if not exists admin_fee_lease_value numeric(14,4),
  add column if not exists admin_fee_commercial_buy_sell_type text,
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_commercial_lease_type text,
  add column if not exists admin_fee_commercial_lease_value numeric(14,4),
  add column if not exists effective_from date,
  add column if not exists effective_to date,
  add column if not exists is_promotion boolean not null default false;

create table if not exists public.dv_accounting_agent_fee_rules(
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  fee_plan_id uuid references public.dv_accounting_fee_plans(id),
  name text not null,
  effective_from date not null,
  effective_to date,
  desk_fee numeric(14,2),
  admin_fee_buy_sell_type text,
  admin_fee_buy_sell_value numeric(14,4),
  admin_fee_lease_type text,
  admin_fee_lease_value numeric(14,4),
  admin_fee_commercial_buy_sell_type text,
  admin_fee_commercial_buy_sell_value numeric(14,4),
  admin_fee_commercial_lease_type text,
  admin_fee_commercial_lease_value numeric(14,4),
  lead_fee_buy_sell_type text,
  lead_fee_buy_sell_value numeric(14,4),
  lead_fee_lease_type text,
  lead_fee_lease_value numeric(14,4),
  commission_split_percent numeric(7,4),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to >= effective_from)
);

create index if not exists idx_dv_agent_fee_rules_agent_dates
  on public.dv_accounting_agent_fee_rules(agent_id,effective_from,effective_to);

create table if not exists public.dv_accounting_commission_charges(
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references public.dv_accounting_commissions(id) on delete cascade,
  transaction_id uuid references public.dv_accounting_transactions(id),
  agent_id uuid references public.dv_accounting_agents(id),
  charge_type text not null,
  description text not null,
  amount numeric(14,2) not null default 0,
  source_rule_id uuid references public.dv_accounting_agent_fee_rules(id),
  created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_commission_cheques(
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.dv_accounting_companies(id),
  agent_id uuid not null references public.dv_accounting_agents(id),
  commission_id uuid references public.dv_accounting_commissions(id),
  cheque_number text,
  cheque_date date not null default current_date,
  gross_commission numeric(14,2) not null default 0,
  agent_share numeric(14,2) not null default 0,
  total_fees numeric(14,2) not null default 0,
  adjustments numeric(14,2) not null default 0,
  net_amount numeric(14,2) generated always as(agent_share-total_fees+adjustments) stored,
  status text not null default 'DRAFT' check(status in ('DRAFT','APPROVED','ISSUED','VOID')),
  issued_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_dv_commission_cheques_agent_date
  on public.dv_accounting_commission_cheques(agent_id,cheque_date);

create table if not exists public.dv_accounting_recurring_fee_rules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  name text not null,
  applies_to text not null check(applies_to in ('BROKERAGE','AGENT')),
  agent_id uuid references public.dv_accounting_agents(id) on delete cascade,
  category text,
  description text,
  amount numeric(14,2) not null default 0,
  hst_amount numeric(14,2) not null default 0,
  frequency text not null check(frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY','CUSTOM_DAYS')),
  interval_days integer,
  day_of_month integer,
  start_date date not null,
  end_date date,
  next_run_date date not null,
  branch_id uuid references public.dv_accounting_branches(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(amount >= 0),
  check(end_date is null or end_date >= start_date)
);

create index if not exists idx_dv_recurring_fee_rules_due
  on public.dv_accounting_recurring_fee_rules(company_id,next_run_date,active);

create table if not exists public.dv_accounting_recurring_fee_runs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  run_date date not null,
  status text not null default 'POSTED',
  created_at timestamptz not null default now(),
  unique(company_id,run_date)
);

alter table public.dv_accounting_agent_fee_rules enable row level security;
alter table public.dv_accounting_commission_charges enable row level security;
alter table public.dv_accounting_commission_cheques enable row level security;
alter table public.dv_accounting_recurring_fee_rules enable row level security;
alter table public.dv_accounting_recurring_fee_runs enable row level security;

do $$ declare t text; begin
 for t in select unnest(array[
  'dv_accounting_agent_fee_rules',
  'dv_accounting_commission_charges',
  'dv_accounting_commission_cheques',
  'dv_accounting_recurring_fee_rules',
  'dv_accounting_recurring_fee_runs'
 ]) loop
  execute format('drop policy if exists "authenticated access" on public.%I',t);
  execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;

-- Returns the active fee rule for an agent on a specific date.
create or replace function public.dv_accounting_get_agent_fee_rule(
  p_agent_id uuid,
  p_as_of date
) returns uuid
language sql stable security definer set search_path=public
as $$
  select r.id
  from public.dv_accounting_agent_fee_rules r
  where r.agent_id=p_agent_id
    and r.active
    and r.effective_from <= p_as_of
    and (r.effective_to is null or r.effective_to >= p_as_of)
  order by r.effective_from desc, r.created_at desc
  limit 1
$$;

-- Calculate the transaction fees that will be used when the agent commission is issued.
-- The result is informational; issuing the cheque snapshots the amounts into commission_charges.
create or replace function public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  a public.dv_accounting_agents%rowtype;
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 90;
  admin_type text;
  admin_value numeric := 0;
  lead_type text;
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
  desk_fee numeric := 0;
begin
  select * into a from public.dv_accounting_agents where id=p_agent_id;
  if not found then raise exception 'Agent not found'; end if;
  select * into t from public.dv_accounting_transactions where id=p_transaction_id;
  if not found then raise exception 'Transaction not found'; end if;

  select * into rule
  from public.dv_accounting_agent_fee_rules
  where agent_id=p_agent_id and active
    and effective_from<=p_as_of
    and (effective_to is null or effective_to>=p_as_of)
  order by effective_from desc,created_at desc limit 1;

  if rule.id is not null then
    split_pct:=coalesce(rule.commission_split_percent,split_pct);
    desk_fee:=coalesce(rule.desk_fee,0);
    if t.market_segment='COMMERCIAL' and t.side='LEASE' then
      admin_type:=coalesce(rule.admin_fee_commercial_lease_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_commercial_lease_value,0);
    elsif t.market_segment='COMMERCIAL' then
      admin_type:=coalesce(rule.admin_fee_commercial_buy_sell_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_commercial_buy_sell_value,0);
    elsif t.side='LEASE' then
      admin_type:=coalesce(rule.admin_fee_lease_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_lease_value,0);
    else
      admin_type:=coalesce(rule.admin_fee_buy_sell_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_buy_sell_value,0);
    end if;
    if t.side='LEASE' then
      lead_type:=coalesce(rule.lead_fee_lease_type,'AMOUNT');
      lead_value:=coalesce(rule.lead_fee_lease_value,0);
    else
      lead_type:=coalesce(rule.lead_fee_buy_sell_type,'AMOUNT');
      lead_value:=coalesce(rule.lead_fee_buy_sell_value,0);
    end if;
  else
    select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
    if fs.id is not null then
      if fs.fee_plan_id is not null then select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id; end if;
      split_pct:=coalesce(fs.commission_split_override_percent,plan.commission_split_percent,split_pct);
      desk_fee:=coalesce(fs.desk_fee_override,plan.desk_fee,0);
      if t.market_segment='COMMERCIAL' and t.side='LEASE' then
        admin_type:=coalesce(fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
      elsif t.market_segment='COMMERCIAL' then
        admin_type:=coalesce(fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
      elsif t.side='LEASE' then
        admin_type:=coalesce(fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
      else
        admin_type:=coalesce(fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
      end if;
      if t.side='LEASE' then
        lead_type:=coalesce(fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
        lead_value:=coalesce(fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
      else
        lead_type:=coalesce(fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
        lead_value:=coalesce(fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
      end if;
    else
      split_pct:=coalesce(plan.commission_split_percent,split_pct);
      desk_fee:=coalesce(plan.desk_fee,0);
    end if;
  end if;

  agent_share:=round(coalesce(p_gross_commission,0)*split_pct/100,2);
  if admin_type='PERCENT' then admin_fee:=round(p_gross_commission*admin_value/100,2); else admin_fee:=round(admin_value,2); end if;
  if lead_type='PERCENT' then lead_fee:=round(p_gross_commission*lead_value/100,2); else lead_fee:=round(lead_value,2); end if;

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

-- Issue a commission cheque and freeze the fee calculation at issuance.
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
  total_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);

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
    source_rule_id
  )
  select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end
  from jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
    )
  ) as x(charge_type text,description text,amount numeric);

  update public.dv_accounting_commissions
  set status='PAID',paid_date=p_cheque_date
  where id=c.id;

  return jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),
    'calculation',calc
  );
end $$;

grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) to authenticated;

-- One-click recurring processing. It creates brokerage expenses and agent charges for all rules due on the run date.
create or replace function public.dv_accounting_run_recurring_fees(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  r public.dv_accounting_recurring_fee_rules%rowtype;
  company uuid;
  created_count integer := 0;
  skipped_count integer := 0;
  period_end date;
begin
  for r in
    select * from public.dv_accounting_recurring_fee_rules
    where active and next_run_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_run_date,created_at
  loop
    company:=r.company_id;

    if r.applies_to='BROKERAGE' then
      insert into public.dv_accounting_expenses(company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status)
      values(company,p_run_date,'Recurring','RECURRING',r.description,r.amount,r.hst_amount,'OPEN','UNPAID');
      created_count:=created_count+1;
    else
      -- Agent recurring charges are kept as commission-style charges until collected/deducted.
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount
      )
      select null,null,r.agent_id,'RECURRING_FEE',coalesce(r.description,r.name),r.amount;
      created_count:=created_count+1;
    end if;

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

  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count);
end $$;

grant execute on function public.dv_accounting_run_recurring_fees(date) to authenticated;
