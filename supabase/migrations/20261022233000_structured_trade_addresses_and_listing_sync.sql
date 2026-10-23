-- Normalize legacy trade-submission lawyer and brokerage addresses into
-- address / unit / city / province / postal-code JSON fields. The UI also
-- normalizes these values on read, so old submissions remain usable if this
-- migration has not yet been applied.
create or replace function public.dv_accounting_parse_legacy_address(p_address text)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_parts text[];
  v_part text;
  v_address text;
  v_unit text := '';
  v_city text := '';
  v_province text := 'ON';
  v_postal text := '';
  v_postal_match text[];
  v_prefix text;
begin
  if nullif(trim(p_address), '') is null then
    return jsonb_build_object('address', '', 'unit', '', 'city', '', 'province', 'ON', 'postal_code', '');
  end if;

  v_parts := regexp_split_to_array(trim(p_address), '\s*,\s*');
  v_address := trim(v_parts[1]);

  if array_length(v_parts, 1) > 1 then
    for i in 2..array_length(v_parts, 1) loop
      v_part := trim(v_parts[i]);
      if v_part ~* '^(unit|suite|ste\.?|#)\s*' then
        v_unit := regexp_replace(v_part, '^(unit|suite|ste\.?|#)\s*', '', 'i');
      else
        v_postal_match := regexp_match(v_part, '([A-Z][0-9][A-Z]\s*[0-9][A-Z][0-9])$','i');
        if v_postal_match is not null then
          v_postal := upper(regexp_replace(v_postal_match[1], '\s+', ' ', 'g'));
          v_prefix := trim(regexp_replace(v_part, '([A-Z][0-9][A-Z]\s*[0-9][A-Z][0-9])$', '', 'i'));
          if v_prefix ~* '^(ON|Ontario|AB|Alberta|BC|British Columbia|QC|Quebec|MB|Manitoba|SK|Saskatchewan|NS|Nova Scotia|NB|New Brunswick|NL|Newfoundland and Labrador|PE|Prince Edward Island|YT|Yukon|NT|Northwest Territories|NU|Nunavut)$' then
            v_province := v_prefix;
          elsif v_prefix <> '' and v_city = '' then
            v_city := v_prefix;
          end if;
        elsif v_part ~* '^(ON|Ontario|AB|Alberta|BC|British Columbia|QC|Quebec|MB|Manitoba|SK|Saskatchewan|NS|Nova Scotia|NB|New Brunswick|NL|Newfoundland and Labrador|PE|Prince Edward Island|YT|Yukon|NT|Northwest Territories|NU|Nunavut)$' then
          v_province := v_part;
        elsif v_city = '' then
          v_city := v_part;
        end if;
      end if;
    end loop;
  end if;

  v_address := regexp_replace(v_address, '\s+(unit|suite|ste\.?|#)\s*[\w-]+\s*$', '', 'i');
  return jsonb_build_object('address', trim(v_address), 'unit', v_unit, 'city', v_city, 'province', v_province, 'postal_code', v_postal);
end;
$$;

do $$
declare
  v_prefix text;
  v_trade record;
  v_parsed jsonb;
  v_payload jsonb;
begin
  foreach v_prefix in array array['seller_lawyer','buyer_lawyer','listing_brokerage','buyer_brokerage'] loop
    for v_trade in
      select id, payload
      from public.dv_accounting_agent_trade_submissions
      where nullif(payload ->> (v_prefix || '_address'), '') is not null
        and position(',' in (payload ->> (v_prefix || '_address'))) > 0
        and coalesce(payload ->> (v_prefix || '_city'), '') = ''
        and coalesce(payload ->> (v_prefix || '_postal_code'), '') = ''
    loop
      v_parsed := public.dv_accounting_parse_legacy_address(v_trade.payload ->> (v_prefix || '_address'));
      v_payload := jsonb_set(v_trade.payload, array[v_prefix || '_address'], to_jsonb(coalesce(v_parsed ->> 'address','')), true);
      v_payload := jsonb_set(v_payload, array[v_prefix || '_unit'], to_jsonb(coalesce(v_parsed ->> 'unit','')), true);
      v_payload := jsonb_set(v_payload, array[v_prefix || '_city'], to_jsonb(coalesce(v_parsed ->> 'city','')), true);
      v_payload := jsonb_set(v_payload, array[v_prefix || '_province'], to_jsonb(coalesce(v_parsed ->> 'province','ON')), true);
      v_payload := jsonb_set(v_payload, array[v_prefix || '_postal_code'], to_jsonb(coalesce(v_parsed ->> 'postal_code','')), true);
      update public.dv_accounting_agent_trade_submissions
      set payload = v_payload, updated_at = now()
      where id = v_trade.id;
    end loop;
  end loop;
end;
$$;

-- Backfill property-address components for existing transactions linked to a
-- listing. New listing-deposit transactions now carry these fields as well.
update public.dv_accounting_transactions t
set
  property_address = coalesce(nullif(l.property_address, ''), t.property_address),
  street_number = coalesce(nullif(substring(l.property_address from '^([0-9]+[A-Za-z]?([-/][0-9]+[A-Za-z]?)?)'), ''), t.street_number),
  street_name = coalesce(nullif(trim(regexp_replace(l.property_address, '^[0-9]+[A-Za-z]?([-/][0-9]+[A-Za-z]?)?\s*', '')), ''), t.street_name),
  unit_number = coalesce(nullif(l.unit_number, ''), t.unit_number),
  city = coalesce(nullif(l.city, ''), t.city),
  province = coalesce(nullif(l.province, ''), t.province, 'ON'),
  postal_code = coalesce(nullif(l.postal_code, ''), t.postal_code),
  mls_number = coalesce(nullif(l.mls_number, ''), t.mls_number)
from public.dv_accounting_listing_submissions l
where t.listing_id = l.id;
