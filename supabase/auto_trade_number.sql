-- Generate globally unique daily trade numbers for agent trade submissions.
-- Run this script in the DV Back Office Production Supabase SQL Editor.
-- Format: TRYYMMDD01, TRYYMMDD02, ...; numbering is shared across all agents.

alter table public.dv_accounting_agent_trade_submissions
  add column if not exists trade_number text;

create unique index if not exists dv_accounting_agent_trade_submissions_trade_number_uidx
  on public.dv_accounting_agent_trade_submissions (trade_number)
  where trade_number is not null;

create or replace function public.dv_assign_agent_trade_number()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  local_day text;
  number_prefix text;
  next_number integer;
begin
  if tg_op = 'UPDATE' then
    new.trade_number := old.trade_number;
    new.payload := coalesce(new.payload, '{}'::jsonb) || jsonb_build_object('transaction_number', old.trade_number);
    return new;
  end if;

  local_day := to_char(timezone('America/Toronto', now()), 'YYMMDD');
  number_prefix := 'TR' || local_day;

  -- Serialize allocation for this date so simultaneous uploads from different agents
  -- cannot receive the same number.
  perform pg_advisory_xact_lock(hashtext('dv-agent-trade-number-' || number_prefix)::bigint);

  select coalesce(max(substring(trade_number from length(number_prefix) + 1)::integer), 0) + 1
    into next_number
    from public.dv_accounting_agent_trade_submissions
   where trade_number like number_prefix || '%'
     and substring(trade_number from length(number_prefix) + 1) ~ '^[0-9]+$';

  new.trade_number := number_prefix || lpad(next_number::text, 2, '0');
  new.payload := coalesce(new.payload, '{}'::jsonb) || jsonb_build_object('transaction_number', new.trade_number);
  return new;
end;
$$;

drop trigger if exists dv_assign_agent_trade_number_before_insert
  on public.dv_accounting_agent_trade_submissions;

create trigger dv_assign_agent_trade_number_before_insert
before insert on public.dv_accounting_agent_trade_submissions
for each row execute function public.dv_assign_agent_trade_number();

-- Existing rows are intentionally left unchanged. All new submissions receive a number.
-- The unique index is the final database-level safeguard against duplicate trade numbers.