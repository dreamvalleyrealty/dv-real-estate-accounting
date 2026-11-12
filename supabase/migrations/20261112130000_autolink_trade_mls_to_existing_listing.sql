-- Automatically attach a trade/transaction to the one existing listing that owns its MLS number.
-- This prevents a valid listing-linked trade from being rejected as an MLS duplicate
-- when the UI omits the dedicated listing_id but the MLS identifies one unique listing.
create or replace function public.dv_accounting_autolink_mls_listing()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_mls text;
  v_listing_ids uuid[];
begin
  if tg_table_name = 'dv_accounting_transactions' then
    v_mls := nullif(upper(btrim(coalesce(new.mls_number, ''))), '');
  else
    v_mls := nullif(upper(btrim(coalesce(new.payload->>'mls_number', ''))), '');
  end if;
  if v_mls is null or v_mls = 'EXCLUSIVE' or new.listing_id is not null then return new; end if;
  select array_agg(l.id order by l.created_at desc) into v_listing_ids
  from public.dv_accounting_listing_submissions l
  where nullif(upper(btrim(coalesce(l.mls_number, ''))), '') = v_mls;
  if coalesce(array_length(v_listing_ids, 1), 0) = 1 then
    new.listing_id := v_listing_ids[1];
    if tg_table_name = 'dv_accounting_agent_trade_submissions' then
      new.payload := jsonb_set(coalesce(new.payload, '{}'::jsonb), '{listing_id}', to_jsonb(new.listing_id), true);
    end if;
  end if;
  return new;
end;
$function$;
drop trigger if exists aaa_dv_autolink_mls_listing_transaction on public.dv_accounting_transactions;
create trigger aaa_dv_autolink_mls_listing_transaction
before insert or update of mls_number, listing_id on public.dv_accounting_transactions
for each row execute function public.dv_accounting_autolink_mls_listing();
drop trigger if exists aaa_dv_autolink_mls_listing_submission on public.dv_accounting_agent_trade_submissions;
create trigger aaa_dv_autolink_mls_listing_submission
before insert or update of payload, listing_id, transaction_id on public.dv_accounting_agent_trade_submissions
for each row execute function public.dv_accounting_autolink_mls_listing();
