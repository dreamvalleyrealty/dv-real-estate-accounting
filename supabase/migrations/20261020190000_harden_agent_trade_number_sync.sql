-- Keep the issued trade number synchronized across the submission payload and
-- the linked transaction. Never generate a replacement number for an existing row.

create or replace function public.dv_preserve_agent_trade_submission_payload()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  v_trade_number text;
begin
  if tg_op = 'UPDATE' then
    -- The submission's issued number is immutable after creation.
    v_trade_number := coalesce(nullif(btrim(old.trade_number), ''), nullif(btrim(new.trade_number), ''));
    new.trade_number := v_trade_number;
    new.payload := coalesce(old.payload, '{}'::jsonb) || coalesce(new.payload, '{}'::jsonb);

    if v_trade_number is not null then
      new.payload := jsonb_set(new.payload, '{transaction_number}', to_jsonb(v_trade_number), true);
    else
      new.payload := new.payload - 'transaction_number';
    end if;
  else
    new.payload := coalesce(new.payload, '{}'::jsonb);
    if nullif(btrim(new.trade_number), '') is not null then
      new.payload := jsonb_set(new.payload, '{transaction_number}', to_jsonb(new.trade_number), true);
    end if;
  end if;

  return new;
end;
$function$;

-- Backfill every existing submission payload from the authoritative trade_number
-- column without replacing any other submitted data.
update public.dv_accounting_agent_trade_submissions s
set payload = jsonb_set(coalesce(s.payload, '{}'::jsonb), '{transaction_number}', to_jsonb(s.trade_number), true)
where nullif(btrim(s.trade_number), '') is not null
  and coalesce(s.payload->>'transaction_number', '') <> s.trade_number;

-- Restore the number on linked transactions when it is currently missing.
-- Skip any number already used by a different transaction to respect the unique index.
update public.dv_accounting_transactions t
set transaction_number = s.trade_number,
    trade_number = coalesce(nullif(btrim(t.trade_number), ''), s.trade_number)
from public.dv_accounting_agent_trade_submissions s
where s.transaction_id = t.id
  and nullif(btrim(s.trade_number), '') is not null
  and (t.transaction_number is null or btrim(t.transaction_number) = '')
  and not exists (
    select 1
    from public.dv_accounting_transactions other_t
    where other_t.id <> t.id
      and other_t.transaction_number = s.trade_number
      and btrim(other_t.transaction_number) <> ''
  );

-- Future updates keep the number in payload synchronized, even when an edit
-- touches unrelated submission fields.
drop trigger if exists trg_preserve_agent_trade_submission_payload
  on public.dv_accounting_agent_trade_submissions;
create trigger trg_preserve_agent_trade_submission_payload
before update on public.dv_accounting_agent_trade_submissions
for each row execute function public.dv_preserve_agent_trade_submission_payload();
