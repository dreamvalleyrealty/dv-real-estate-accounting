-- Preserve legacy payload numbers if an older submission has no dedicated trade_number.
-- The dedicated column remains authoritative whenever it is populated.
create or replace function public.dv_preserve_agent_trade_submission_payload()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  v_trade_number text;
begin
  if tg_op = 'UPDATE' then
    v_trade_number := coalesce(
      nullif(btrim(old.trade_number), ''),
      nullif(btrim(new.trade_number), ''),
      nullif(btrim(old.payload->>'transaction_number'), ''),
      nullif(btrim(new.payload->>'transaction_number'), '')
    );
    new.trade_number := coalesce(nullif(btrim(old.trade_number), ''), nullif(btrim(new.trade_number), ''));
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