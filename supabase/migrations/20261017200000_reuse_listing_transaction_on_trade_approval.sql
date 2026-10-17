-- Reuse a listing-created accounting transaction during trade approval.
-- Patch the existing ensure function rather than replacing the approval RPC, preserving
-- document validation, all existing field mappings, and current review workflow.
do $migration$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef(p.oid)
    into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'dv_accounting_ensure_agent_trade_transaction'
    and pg_get_function_identity_arguments(p.oid) = 'p_submission_id uuid';

  if v_definition is null then
    raise exception 'Could not find dv_accounting_ensure_agent_trade_transaction(uuid)';
  end if;

  if position('where listing_id = nullif(trim(coalesce(p->>''listing_id'','''')), '''')::uuid' in v_definition) > 0 then
    raise notice 'Listing transaction reuse logic is already installed';
    return;
  end if;

  v_updated := replace(
    v_definition,
    '  v_tx_id := s.transaction_id;',
    $insert$
  v_tx_id := s.transaction_id;

  -- If the submission is linked to an existing listing, reuse that listing's
  -- accounting transaction before creating a new one.
  if v_tx_id is null and nullif(trim(coalesce(p->>'listing_id','')), '') is not null then
    select id into v_tx_id
    from public.dv_accounting_transactions
    where listing_id = nullif(trim(coalesce(p->>'listing_id','')), '')::uuid
    order by created_at asc
    limit 1
    for update;
  end if;

  -- If a transaction number already exists, reuse it to avoid duplicate records.
  if v_tx_id is null then
    select id into v_tx_id
    from public.dv_accounting_transactions
    where transaction_number = v_tx_no
    order by created_at asc
    limit 1
    for update;
  end if;
$insert$
  );

  if v_updated = v_definition then
    raise exception 'Could not safely patch the transaction ensure function; expected anchor was not found';
  end if;

  -- Normalize commission side to the values permitted by the commission table check.
  v_updated := replace(
    v_updated,
    'coalesce(nullif(p->>''side'',''''),''BUYER'')',
    'case upper(coalesce(nullif(trim(p->>''side''),''''),''BUYER'')) when ''SELLER'' then ''LISTING'' when ''LANDLORD'' then ''LISTING'' when ''TENANT'' then ''BUYER'' when ''BUYER'' then ''BUYER'' when ''LISTING'' then ''LISTING'' else ''BUYER'' end'
  );

  execute v_updated;
end;
$migration$;
