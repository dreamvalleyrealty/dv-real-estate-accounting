-- Normalize legacy combined addresses in every directory, listing, and transaction
-- table. Keep populated structured values and fill only missing components.
do $$
declare
  r record;
  p jsonb;
begin
  for r in
    select id, address, unit, city, province, postal_code, 'dv_accounting_contacts'::text as source_table
    from public.dv_accounting_contacts
    where coalesce(address,'') like '%,%'
    union all
    select id, address, unit, city, province, postal_code, 'dv_accounting_law_firms'::text
    from public.dv_accounting_law_firms
    where coalesce(address,'') like '%,%'
    union all
    select id, address, unit, city, province, postal_code, 'dv_accounting_external_brokerages'::text
    from public.dv_accounting_external_brokerages
    where coalesce(address,'') like '%,%'
    union all
    select id, address, unit, city, province, postal_code, 'dv_accounting_transaction_people'::text
    from public.dv_accounting_transaction_people
    where coalesce(address,'') like '%,%'
    union all
    select id, address, unit, city, province, postal_code, 'dv_accounting_transaction_outside_brokers'::text
    from public.dv_accounting_transaction_outside_brokers
    where coalesce(address,'') like '%,%'
  loop
    p := public.dv_accounting_parse_legacy_address(r.address);
    if r.source_table = 'dv_accounting_contacts' then
      update public.dv_accounting_contacts set
        address = p->>'address',
        unit = coalesce(nullif(unit,''), nullif(p->>'unit','')),
        city = coalesce(nullif(city,''), nullif(p->>'city','')),
        province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
        postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
        updated_at = now()
      where id = r.id;
    elsif r.source_table = 'dv_accounting_law_firms' then
      update public.dv_accounting_law_firms set
        address = p->>'address',
        unit = coalesce(nullif(unit,''), nullif(p->>'unit','')),
        city = coalesce(nullif(city,''), nullif(p->>'city','')),
        province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
        postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
        updated_at = now()
      where id = r.id;
    elsif r.source_table = 'dv_accounting_external_brokerages' then
      update public.dv_accounting_external_brokerages set
        address = p->>'address',
        unit = coalesce(nullif(unit,''), nullif(p->>'unit','')),
        city = coalesce(nullif(city,''), nullif(p->>'city','')),
        province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
        postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
        updated_at = now()
      where id = r.id;
    elsif r.source_table = 'dv_accounting_transaction_people' then
      update public.dv_accounting_transaction_people set
        address = p->>'address',
        unit = coalesce(nullif(unit,''), nullif(p->>'unit','')),
        city = coalesce(nullif(city,''), nullif(p->>'city','')),
        province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
        postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
        updated_at = now()
      where id = r.id;
    elsif r.source_table = 'dv_accounting_transaction_outside_brokers' then
      update public.dv_accounting_transaction_outside_brokers set
        address = p->>'address',
        unit = coalesce(nullif(unit,''), nullif(p->>'unit','')),
        city = coalesce(nullif(city,''), nullif(p->>'city','')),
        province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
        postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
        updated_at = now()
      where id = r.id;
    end if;
  end loop;
end;
$$;

-- Normalize listing addresses as well, including old combined address strings.
do $$
declare
  r record;
  p jsonb;
begin
  for r in
    select id, property_address, unit_number, city, province, postal_code
    from public.dv_accounting_listing_submissions
    where coalesce(property_address,'') like '%,%'
  loop
    p := public.dv_accounting_parse_legacy_address(r.property_address);
    update public.dv_accounting_listing_submissions set
      property_address = p->>'address',
      unit_number = coalesce(nullif(unit_number,''), nullif(p->>'unit','')),
      city = coalesce(nullif(city,''), nullif(p->>'city','')),
      province = coalesce(nullif(province,''), nullif(p->>'province',''), 'ON'),
      postal_code = coalesce(nullif(postal_code,''), nullif(p->>'postal_code','')),
      updated_at = now()
    where id = r.id;
  end loop;
end;
$$;
