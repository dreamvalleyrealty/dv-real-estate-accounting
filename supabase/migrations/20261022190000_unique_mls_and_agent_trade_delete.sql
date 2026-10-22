-- Enforce MLS-number uniqueness across listings, transactions and trade submissions.
-- The same MLS number is allowed on the linked listing/trade/transaction for that one property.
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

  if v_mls is null then return NEW; end if;

  -- Serialize writes for the same normalized MLS number to prevent race-condition duplicates.
  perform pg_advisory_xact_lock(hashtext('dv_accounting_mls:' || v_mls));

  if TG_TABLE_NAME = 'dv_accounting_listing_submissions' then
    select exists(
      select 1 from public.dv_accounting_transactions t
      where nullif(upper(btrim(t.mls_number)), '') = v_mls
        and t.listing_id is distinct from NEW.id
      union all
      select 1 from public.dv_accounting_agent_trade_submissions s
      where nullif(upper(btrim(coalesce(s.payload->>'mls_number',''))), '') = v_mls
        and coalesce(s.listing_id, (select t2.listing_id from public.dv_accounting_transactions t2 where t2.id=s.transaction_id)) is distinct from NEW.id
    ) into v_duplicate;
  elsif TG_TABLE_NAME = 'dv_accounting_transactions' then
    select exists(
      select 1 from public.dv_accounting_transactions t
      where t.id is distinct from NEW.id
        and nullif(upper(btrim(t.mls_number)), '') = v_mls
        and t.listing_id is distinct from NEW.listing_id
      union all
      select 1 from public.dv_accounting_listing_submissions l
      where nullif(upper(btrim(l.mls_number)), '') = v_mls
        and l.id is distinct from NEW.listing_id
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
      where s.id is distinct from NEW.id
        and nullif(upper(btrim(coalesce(s.payload->>'mls_number',''))), '') = v_mls
      union all
      select 1 from public.dv_accounting_listing_submissions l
      where nullif(upper(btrim(l.mls_number)), '') = v_mls
        and l.id is distinct from NEW.listing_id
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

drop trigger if exists trg_dv_listing_submission_unique_mls on public.dv_accounting_listing_submissions;
create trigger trg_dv_listing_submission_unique_mls
before insert or update of mls_number on public.dv_accounting_listing_submissions
for each row execute function public.dv_accounting_check_unique_mls_number();

drop trigger if exists trg_dv_transaction_unique_mls on public.dv_accounting_transactions;
create trigger trg_dv_transaction_unique_mls
before insert or update of mls_number, listing_id, transaction_number on public.dv_accounting_transactions
for each row execute function public.dv_accounting_check_unique_mls_number();

drop trigger if exists trg_dv_trade_submission_unique_mls on public.dv_accounting_agent_trade_submissions;
create trigger trg_dv_trade_submission_unique_mls
before insert or update of payload, listing_id, transaction_id on public.dv_accounting_agent_trade_submissions
for each row execute function public.dv_accounting_check_unique_mls_number();

-- Agents may delete their own unapproved submissions only before a transaction is linked.
-- Approved, linked, closed, and accounting-posted trades remain protected.
create or replace function public.dv_accounting_agent_delete_trade_submission(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in to delete a trade submission';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Trade submission not found'; end if;

  if not exists (
    select 1
    from public.dv_accounting_agents a
    where a.id = s.agent_id
      and lower(btrim(a.email)) = lower(btrim(coalesce(auth.jwt()->>'email','')))
  ) then
    raise exception 'You can only delete your own trade submissions';
  end if;

  if upper(coalesce(s.status,'')) not in ('DRAFT','SUBMITTED','NEEDS_CHANGES') then
    raise exception 'Only draft, submitted, or changes-requested trade submissions can be deleted';
  end if;

  if s.transaction_id is not null then
    raise exception 'This trade is already linked to accounting and cannot be deleted here. Contact the Trade Admin Manager.';
  end if;

  delete from public.dv_accounting_agent_trade_documents where submission_id = s.id;
  delete from public.dv_accounting_agent_trade_submissions where id = s.id;

  return jsonb_build_object('deleted', true, 'submission_id', s.id);
end;
$$;

revoke all on function public.dv_accounting_agent_delete_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_agent_delete_trade_submission(uuid) to authenticated;

notify pgrst, 'reload schema';
