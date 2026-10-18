-- Allocate the standard TR number when a listing first receives a deposit.
-- A trade submission created later for that listing reuses this exact number.
create or replace function public.dv_accounting_next_trade_number()
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  local_day text;
  v_number_prefix text;
  next_number bigint;
begin
  local_day := to_char(timezone('America/Toronto', now()), 'YYMMDD');
  v_number_prefix := 'TR' || local_day;
  insert into public.dv_agent_trade_number_counters as counter(number_prefix,last_number)
  values(v_number_prefix,1)
  on conflict(number_prefix)
  do update set last_number=counter.last_number+1
  returning counter.last_number into next_number;
  return v_number_prefix || lpad(next_number::text,2,'0');
end;
$function$;
grant execute on function public.dv_accounting_next_trade_number() to authenticated;

-- Reuse a listing's already-issued TR number when its trade submission is created.
-- Otherwise retain the existing atomic daily counter behavior.
create or replace function public.dv_assign_agent_trade_number()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  local_day text;
  v_number_prefix text;
  next_number bigint;
  v_listing_id uuid;
  v_listing_trade_number text;
begin
  if tg_op = 'UPDATE' then
    new.trade_number := old.trade_number;
    new.payload := coalesce(new.payload, '{}'::jsonb) || jsonb_build_object('transaction_number', old.trade_number);
    return new;
  end if;

  v_listing_id := coalesce(
    new.listing_id,
    nullif(trim(coalesce(new.payload->>'listing_id','')),'')::uuid
  );

  if v_listing_id is not null then
    select t.transaction_number into v_listing_trade_number
    from public.dv_accounting_transactions t
    where t.listing_id = v_listing_id
      and t.transaction_number ~ '^TR[0-9]{6}[0-9]+$'
    order by
      case when exists (
        select 1 from public.dv_accounting_trust_transactions tt
        where tt.transaction_id=t.id
          and tt.direction='DEPOSIT'
          and tt.trust_account_type='REAL_ESTATE_TRUST'
          and tt.status='POSTED'
      ) then 0 else 1 end,
      t.created_at asc
    limit 1
    for update;

    if v_listing_trade_number is not null and not exists (
      select 1 from public.dv_accounting_agent_trade_submissions s
      where s.trade_number=v_listing_trade_number
    ) then
      new.trade_number := v_listing_trade_number;
      new.payload := coalesce(new.payload,'{}'::jsonb) || jsonb_build_object('transaction_number',v_listing_trade_number);
      return new;
    end if;
  end if;

  local_day := to_char(timezone('America/Toronto', now()), 'YYMMDD');
  v_number_prefix := 'TR' || local_day;
  insert into public.dv_agent_trade_number_counters as counter(number_prefix,last_number)
  values(v_number_prefix,1)
  on conflict(number_prefix)
  do update set last_number=counter.last_number+1
  returning counter.last_number into next_number;

  new.trade_number := v_number_prefix || lpad(next_number::text,2,'0');
  new.payload := coalesce(new.payload,'{}'::jsonb) || jsonb_build_object('transaction_number',new.trade_number);
  return new;
end;
$function$;
