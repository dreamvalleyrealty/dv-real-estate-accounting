-- Allow the shared placeholder MLS value EXCLUSIVE on multiple records.
-- Real MLS numbers remain unique across listings, trade submissions and transactions.
create or replace function public.dv_accounting_check_unique_mls_number()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_mls text;
  v_duplicate boolean := false;
begin
  if TG_TABLE_NAME = 'dv_accounting_listing_submissions' then
    v_mls := nullif(upper(btrim(NEW.mls_number)), '');
  elsif TG_TABLE_NAME = 'dv_accounting_transactions' then
    v_mls := nullif(upper(btrim(NEW.mls_number)), '');
  else
    v_mls := nullif(upper(btrim(coalesce(NEW.payload->>'mls_number',''))), '');
  end if;

  if v_mls is null or v_mls = 'EXCLUSIVE' then
    return NEW;
  end if;

  perform pg_advisory_xact_lock(hashtext('dv_accounting_mls:' || v_mls));

  if TG_TABLE_NAME = 'dv_accounting_listing_submissions' then
    select exists(
      select 1 from public.dv_accounting_listing_submissions l
      where l.id is distinct from NEW.id and nullif(upper(btrim(l.mls_number)), '') = v_mls
      union all
      select 1 from public.dv_accounting_transactions t
      where nullif(upper(btrim(t.mls_number)), '') = v_mls and t.listing_id is distinct from NEW.id
      union all
      select 1 from public.dv_accounting_agent_trade_submissions s
      where nullif(upper(btrim(coalesce(s.payload->>'mls_number',''))), '') = v_mls
        and coalesce(s.listing_id, (select t2.listing_id from public.dv_accounting_transactions t2 where t2.id=s.transaction_id)) is distinct from NEW.id
    ) into v_duplicate;
  elsif TG_TABLE_NAME = 'dv_accounting_transactions' then
    select exists(
      select 1 from public.dv_accounting_transactions t
      where t.id is distinct from NEW.id and nullif(upper(btrim(t.mls_number)), '') = v_mls
        and t.listing_id is distinct from NEW.listing_id
      union all
      select 1 from public.dv_accounting_listing_submissions l
      where nullif(upper(btrim(l.mls_number)), '') = v_mls and l.id is distinct from NEW.listing_id
      union all
      select 1 from public.dv_accounting_agent_trade_submissions s
      where nullif(upper(btrim(coalesce(s.payload->>'mls_number',''))), '') = v_mls
        and s.transaction_id is distinct from NEW.id
        and coalesce(s.listing_id, (select t2.listing_id from public.dv_accounting_transactions t2 where t2.id=s.transaction_id)) is distinct from NEW.listing_id
        and nullif(upper(btrim(coalesce(s.payload->>'transaction_number',''))), '') is distinct from nullif(upper(btrim(coalesce(NEW.transaction_number,''))), '')
    ) into v_duplicate;
  else
    select exists(
      select 1 from public.dv_accounting_agent_trade_submissions s
      where s.id is distinct from NEW.id and nullif(upper(btrim(coalesce(s.payload->>'mls_number',''))), '') = v_mls
      union all
      select 1 from public.dv_accounting_listing_submissions l
      where nullif(upper(btrim(l.mls_number)), '') = v_mls and l.id is distinct from NEW.listing_id
      union all
      select 1 from public.dv_accounting_transactions t
      where nullif(upper(btrim(t.mls_number)), '') = v_mls
        and t.id is distinct from NEW.transaction_id
        and t.listing_id is distinct from NEW.listing_id
        and nullif(upper(btrim(coalesce(t.transaction_number,''))), '') is distinct from nullif(upper(btrim(coalesce(NEW.payload->>'transaction_number',''))), '')
    ) into v_duplicate;
  end if;
  if v_duplicate then
    raise exception 'MLS number "%" is already in use by another listing, trade submission, or transaction. Enter a unique MLS number.', v_mls
      using errcode = '23505';
  end if;
  return NEW;
end;
$$;
