-- Backfill the outside-broker record for every approved trade that has
-- an external cooperating/listing brokerage in its submission payload.
do $$
declare
  r record;
  v_side text;
  v_company text;
  v_address text;
  v_unit text;
  v_city text;
  v_province text;
  v_postal text;
  v_phone text;
  v_fax text;
  v_agent_name text;
  v_agent_email text;
  v_existing_id uuid;
begin
  for r in
    select id, transaction_id, payload
    from public.dv_accounting_agent_trade_submissions
    where status = 'APPROVED'
      and transaction_id is not null
  loop
    v_side := upper(coalesce(r.payload->>'side','BUYER'));
    if v_side in ('SELLER','LANDLORD','LISTING') then
      v_company := trim(coalesce(r.payload->>'buyer_brokerage_name',''));
      v_address := coalesce(r.payload->>'buyer_brokerage_address','');
      v_unit := coalesce(r.payload->>'buyer_brokerage_unit','');
      v_city := coalesce(r.payload->>'buyer_brokerage_city','');
      v_province := coalesce(r.payload->>'buyer_brokerage_province','ON');
      v_postal := coalesce(r.payload->>'buyer_brokerage_postal_code','');
      v_phone := coalesce(r.payload->>'buyer_brokerage_phone','');
      v_fax := coalesce(r.payload->>'buyer_brokerage_fax','');
      v_agent_name := coalesce(r.payload->>'buyer_agent_name','');
      v_agent_email := coalesce(r.payload->>'buyer_agent_email','');
    else
      v_company := trim(coalesce(r.payload->>'listing_brokerage_name',''));
      v_address := coalesce(r.payload->>'listing_brokerage_address','');
      v_unit := coalesce(r.payload->>'listing_brokerage_unit','');
      v_city := coalesce(r.payload->>'listing_brokerage_city','');
      v_province := coalesce(r.payload->>'listing_brokerage_province','ON');
      v_postal := coalesce(r.payload->>'listing_brokerage_postal_code','');
      v_phone := coalesce(r.payload->>'listing_brokerage_phone','');
      v_fax := coalesce(r.payload->>'listing_brokerage_fax','');
      v_agent_name := coalesce(r.payload->>'listing_agent_name','');
      v_agent_email := coalesce(r.payload->>'listing_agent_email','');
    end if;

    if v_company = '' or lower(v_company) = 'dream valley realty inc., brokerage' then
      continue;
    end if;

    select id into v_existing_id
      from public.dv_accounting_transaction_outside_brokers
     where transaction_id = r.transaction_id
     order by created_at asc
     limit 1;

    if v_existing_id is null then
      insert into public.dv_accounting_transaction_outside_brokers
        (transaction_id, company_name, address, unit, city, province, postal_code, phone, fax, agent_name, agent_email)
      values
        (r.transaction_id, v_company, v_address, v_unit, v_city, coalesce(nullif(v_province,''),'ON'), v_postal, v_phone, v_fax, v_agent_name, v_agent_email);
    else
      update public.dv_accounting_transaction_outside_brokers
         set company_name = v_company,
             address = v_address,
             unit = v_unit,
             city = v_city,
             province = coalesce(nullif(v_province,''),'ON'),
             postal_code = v_postal,
             phone = v_phone,
             fax = v_fax,
             agent_name = v_agent_name,
             agent_email = v_agent_email,
             updated_at = now()
       where id = v_existing_id;
    end if;
  end loop;
end;
$$;
