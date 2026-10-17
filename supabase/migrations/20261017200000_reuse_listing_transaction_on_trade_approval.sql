-- Reuse the listing-created accounting transaction when approving a trade linked to that listing.
-- This prevents a listing and its trade submission from becoming two accounting transactions.
create or replace function public.dv_accounting_approve_agent_trade_submission(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions;
  p jsonb;
  tx public.dv_accounting_transactions;
  new_tx_id uuid;
  listing_uuid uuid;
  buyer text;
  seller text;
  tx_no text;
  address_text text;
  side_text text;
  transaction_type_text text;
  sale_price_value numeric;
  commission_value numeric;
  deposit_value numeric;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only the Trade Admin Manager or an administrator can approve trade submissions';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if s.id is null then raise exception 'Trade submission not found'; end if;
  if s.status = 'APPROVED' and s.transaction_id is not null then return s.transaction_id; end if;
  if s.status <> 'SUBMITTED' then raise exception 'Only submitted trades can be approved'; end if;

  p := s.payload;
  buyer := nullif(trim(coalesce(p->>'buyer_name','')), '');
  seller := nullif(trim(coalesce(p->>'seller_name','')), '');
  tx_no := coalesce(nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));
  listing_uuid := nullif(trim(coalesce(p->>'listing_id','')), '')::uuid;
  address_text := coalesce(
    nullif(trim(coalesce(p->>'property_address','')), ''),
    nullif(trim(concat_ws(' ', nullif(p->>'street_number',''), nullif(p->>'street_name',''), case when nullif(p->>'unit_number','') is not null then 'Unit ' || (p->>'unit_number') end)), ''),
    'Address pending'
  );
  side_text := nullif(trim(coalesce(p->>'side','')), '');
  transaction_type_text := coalesce(nullif(trim(coalesce(p->>'transaction_type','')), ''), 'BUY_SELL');
  sale_price_value := coalesce(nullif(p->>'sale_price','')::numeric, nullif(p->>'list_price','')::numeric, nullif(p->>'rent_amount','')::numeric, 0);
  commission_value := coalesce(nullif(p->>'gross_commission','')::numeric, 0);
  deposit_value := coalesce(nullif(p->>'deposit_amount','')::numeric, 0);

  -- First preference: the exact listing linked on the submission.
  if listing_uuid is not null then
    select * into tx
    from public.dv_accounting_transactions
    where listing_id = listing_uuid
    order by created_at asc
    limit 1
    for update;
    if found then new_tx_id := tx.id; end if;
  end if;

  -- Secondary protection for retries/imports where a transaction number already exists.
  if new_tx_id is null then
    select * into tx
    from public.dv_accounting_transactions
    where transaction_number = tx_no
    order by created_at asc
    limit 1
    for update;
    if found then new_tx_id := tx.id; end if;
  end if;

  if new_tx_id is null then
    insert into public.dv_accounting_transactions (
      company_id, transaction_number, status, transaction_date, property_address,
      client_name, side, sale_price, gross_commission, agent_id,
      street_number, street_name, unit_number, city, province, postal_code,
      offer_date, firm_date, close_date, entry_date, mls_number, transaction_type,
      listing_id, deposit_amount
    )
    values (
      (select a.company_id from public.dv_accounting_agents a where a.id = s.agent_id limit 1),
      tx_no, 'DRAFT',
      nullif(p->>'transaction_date','')::date,
      address_text,
      coalesce(nullif(trim(coalesce(p->>'client_name','')), ''), concat_ws(' / ', buyer, seller)),
      side_text,
      sale_price_value,
      commission_value,
      s.agent_id,
      nullif(p->>'street_number',''), nullif(p->>'street_name',''), nullif(p->>'unit_number',''),
      nullif(p->>'city',''), coalesce(nullif(p->>'province',''),'ON'), nullif(p->>'postal_code',''),
      nullif(p->>'offer_date','')::date, nullif(p->>'firm_date','')::date, nullif(p->>'close_date','')::date,
      current_date, nullif(p->>'mls_number',''), transaction_type_text,
      listing_uuid, deposit_value
    )
    returning id into new_tx_id;
  else
    -- Preserve accounting status and existing trust records while enriching the listing transaction
    -- with the reviewed trade submission values.
    update public.dv_accounting_transactions
    set transaction_number = tx_no,
        transaction_date = coalesce(nullif(p->>'transaction_date','')::date, transaction_date),
        property_address = address_text,
        client_name = coalesce(nullif(trim(coalesce(p->>'client_name','')), ''), concat_ws(' / ', buyer, seller), client_name),
        side = coalesce(side_text, side),
        sale_price = case when sale_price_value > 0 then sale_price_value else sale_price end,
        gross_commission = case when commission_value > 0 then commission_value else gross_commission end,
        agent_id = s.agent_id,
        street_number = coalesce(nullif(p->>'street_number',''), street_number),
        street_name = coalesce(nullif(p->>'street_name',''), street_name),
        unit_number = coalesce(nullif(p->>'unit_number',''), unit_number),
        city = coalesce(nullif(p->>'city',''), city),
        province = coalesce(nullif(p->>'province',''), province, 'ON'),
        postal_code = coalesce(nullif(p->>'postal_code',''), postal_code),
        offer_date = coalesce(nullif(p->>'offer_date','')::date, offer_date),
        firm_date = coalesce(nullif(p->>'firm_date','')::date, firm_date),
        close_date = coalesce(nullif(p->>'close_date','')::date, close_date),
        mls_number = coalesce(nullif(p->>'mls_number',''), mls_number),
        transaction_type = coalesce(nullif(p->>'transaction_type',''), transaction_type),
        listing_id = coalesce(listing_uuid, listing_id),
        deposit_amount = case when deposit_value > 0 then deposit_value else deposit_amount end
    where id = new_tx_id;
  end if;

  if buyer is not null and not exists (
    select 1 from public.dv_accounting_transaction_people
    where transaction_id = new_tx_id and person_type = 'BUYER'
      and lower(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,''))) = lower(trim(buyer))
  ) then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(new_tx_id,'BUYER',split_part(buyer,' ',1),nullif(substr(buyer,length(split_part(buyer,' ',1))+2),''),nullif(p->>'buyer_company',''),nullif(p->>'buyer_email',''),nullif(p->>'buyer_phone',''));
  end if;
  if seller is not null and not exists (
    select 1 from public.dv_accounting_transaction_people
    where transaction_id = new_tx_id and person_type = 'SELLER'
      and lower(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,''))) = lower(trim(seller))
  ) then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(new_tx_id,'SELLER',split_part(seller,' ',1),nullif(substr(seller,length(split_part(seller,' ',1))+2),''),nullif(p->>'seller_company',''),nullif(p->>'seller_email',''),nullif(p->>'seller_phone',''));
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status='APPROVED', transaction_id=new_tx_id, reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where id=s.id;

  return new_tx_id;
end;
$$;

revoke all on function public.dv_accounting_approve_agent_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_approve_agent_trade_submission(uuid) to authenticated;
