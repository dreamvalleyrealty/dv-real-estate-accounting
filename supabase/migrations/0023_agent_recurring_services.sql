-- 0023: recurring agent billing plans, desk-fee frequency and added-value services

alter table public.dv_accounting_fee_plans
  add column if not exists desk_fee_frequency text not null default 'MONTHLY'
    check(desk_fee_frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY'));

alter table public.dv_accounting_agent_fee_settings
  add column if not exists desk_fee_frequency text;

alter table public.dv_accounting_agent_fee_rules
  add column if not exists desk_fee_frequency text;

-- Catalog of optional services the brokerage can offer agents.
create table if not exists public.dv_accounting_agent_service_catalog(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  name text not null,
  description text,
  default_amount numeric(14,2) not null default 0,
  default_hst_amount numeric(14,2) not null default 0,
  default_frequency text not null default 'MONTHLY'
    check(default_frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id,name)
);

-- One row per agent/service subscription. next_charge_date is the source of truth
-- for the next time that specific agent is charged.
create table if not exists public.dv_accounting_agent_service_subscriptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  service_id uuid references public.dv_accounting_agent_service_catalog(id) on delete set null,
  service_type text not null default 'ADD_ON'
    check(service_type in ('DESK_FEE','ADD_ON')),
  name text not null,
  amount numeric(14,2) not null default 0,
  hst_amount numeric(14,2) not null default 0,
  frequency text not null
    check(frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY')),
  start_date date not null,
  end_date date,
  next_charge_date date not null,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  check(amount >= 0),
  check(end_date is null or end_date >= start_date)
);

create index if not exists idx_dv_agent_service_subscriptions_due
  on public.dv_accounting_agent_service_subscriptions(company_id,next_charge_date,active);

create index if not exists idx_dv_agent_service_subscriptions_agent
  on public.dv_accounting_agent_service_subscriptions(agent_id,active);

-- Seed/maintain a desk-fee subscription for an agent. Existing active subscription
-- is left alone so changing a plan does not unexpectedly change the next charge.
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
  freq text;
  fee numeric;
begin
  select * into a from public.dv_accounting_agents where id=p_agent_id;
  if not found then raise exception 'Agent not found'; end if;

  select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
  if fs.id is not null and fs.fee_plan_id is not null then
    select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
  end if;

  if plan.id is null then return null; end if;

  fee:=coalesce(fs.desk_fee_override,plan.desk_fee,0);
  freq:=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,'MONTHLY');

  select * into sub
  from public.dv_accounting_agent_service_subscriptions
  where agent_id=p_agent_id and service_type='DESK_FEE' and active
  order by created_at desc limit 1;

  if sub.id is not null then
    return sub.id;
  end if;

  insert into public.dv_accounting_agent_service_subscriptions(
    company_id,agent_id,service_type,name,amount,hst_amount,frequency,
    start_date,next_charge_date,active,notes
  )
  values(
    a.company_id,a.id,'DESK_FEE','Desk Fee',fee,0,freq,
    p_start_date,p_start_date,true,'Created from assigned fee plan'
  )
  returning id into sid;

  return sid;
end $$;

grant execute on function public.dv_accounting_sync_agent_desk_fee_subscription(uuid,date) to authenticated;

-- One-click billing for agent desk fees and added-value services.
-- Each subscription advances its own next_charge_date, so monthly/yearly
-- services never lose their individual billing anniversary.
create or replace function public.dv_accounting_run_agent_service_billing(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  s public.dv_accounting_agent_service_subscriptions%rowtype;
  created_count integer := 0;
  company uuid;
begin
  for s in
    select * from public.dv_accounting_agent_service_subscriptions
    where active
      and next_charge_date <= p_run_date
      and (end_date is null or end_date >= p_run_date)
    order by next_charge_date,created_at
  loop
    insert into public.dv_accounting_commission_charges(
      commission_id,transaction_id,agent_id,charge_type,description,amount,status
    )
    values(
      null,null,s.agent_id,
      case when s.service_type='DESK_FEE' then 'DESK_FEE' else 'ADD_ON_SERVICE' end,
      s.name,s.amount,'OPEN'
    );

    created_count:=created_count+1;

    update public.dv_accounting_agent_service_subscriptions
    set next_charge_date=
      case
        when frequency='MONTHLY' then (next_charge_date + interval '1 month')::date
        when frequency='QUARTERLY' then (next_charge_date + interval '3 months')::date
        when frequency='SEMI_ANNUALLY' then (next_charge_date + interval '6 months')::date
        when frequency='ANNUALLY' then (next_charge_date + interval '1 year')::date
      end,
      active=case
        when end_date is not null and
             (case
               when frequency='MONTHLY' then (next_charge_date + interval '1 month')::date
               when frequency='QUARTERLY' then (next_charge_date + interval '3 months')::date
               when frequency='SEMI_ANNUALLY' then (next_charge_date + interval '6 months')::date
               when frequency='ANNUALLY' then (next_charge_date + interval '1 year')::date
             end) > end_date then false
        else active
      end
    where id=s.id;
  end loop;

  return jsonb_build_object(
    'run_date',p_run_date,
    'created_count',created_count
  );
end $$;

grant execute on function public.dv_accounting_run_agent_service_billing(date) to authenticated;
