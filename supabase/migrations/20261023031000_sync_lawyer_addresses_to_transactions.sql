-- Permit the approved-trade lawyer editor to save structured address parts.
create or replace function public.dv_accounting_agent_save_approved_trade_lawyer_details(
  p_submission_id uuid,
  p_lawyer_details jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_submission public.dv_accounting_agent_trade_submissions;
  v_lawyer_details jsonb;
begin
  select *
    into v_submission
    from public.dv_accounting_agent_trade_submissions
   where id = p_submission_id
   for update;

  if not found then
    raise exception 'Trade submission not found';
  end if;

  if v_submission.submitted_by is distinct from auth.uid() then
    raise exception 'You are not authorized to update lawyer details for this trade';
  end if;

  if v_submission.status <> 'APPROVED' then
    raise exception 'This function is only for approved trades';
  end if;

  select coalesce(jsonb_object_agg(item.key, item.value), '{}'::jsonb)
    into v_lawyer_details
    from jsonb_each(coalesce(p_lawyer_details, '{}'::jsonb)) as item
   where item.key = any (array[
     'seller_lawyer_name',
     'seller_lawyer_firm',
     'seller_lawyer_address',
     'seller_lawyer_unit',
     'seller_lawyer_city',
     'seller_lawyer_province',
     'seller_lawyer_postal_code',
     'seller_lawyer_phone',
     'seller_lawyer_fax',
     'seller_lawyer_email',
     'buyer_lawyer_name',
     'buyer_lawyer_firm',
     'buyer_lawyer_address',
     'buyer_lawyer_unit',
     'buyer_lawyer_city',
     'buyer_lawyer_province',
     'buyer_lawyer_postal_code',
     'buyer_lawyer_phone',
     'buyer_lawyer_fax',
     'buyer_lawyer_email'
   ]::text[]);

  update public.dv_accounting_agent_trade_submissions
     set payload = coalesce(payload, '{}'::jsonb) || v_lawyer_details,
         updated_at = now()
   where id = p_submission_id
   returning * into v_submission;

  return to_jsonb(v_submission);
end;
$$;

revoke all on function public.dv_accounting_agent_save_approved_trade_lawyer_details(uuid, jsonb) from public, anon;
grant execute on function public.dv_accounting_agent_save_approved_trade_lawyer_details(uuid, jsonb) to authenticated;

-- Backfill lawyer information from already-approved submissions into the
-- transaction's People tab. Existing people are updated instead of duplicated.
do $$
declare
  v_submission record;
  v_side text;
  v_person_type text;
  v_full_name text;
  v_firm text;
  v_parts text[];
  v_person_id uuid;
  v_row jsonb;
begin
  for v_submission in
    select transaction_id, payload
    from public.dv_accounting_agent_trade_submissions
    where transaction_id is not null
      and status = 'APPROVED'
    order by updated_at asc
  loop
    foreach v_side in array array['buyer','seller'] loop
      v_full_name := trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_name'), ''));
      v_firm := trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_firm'), ''));
      if v_full_name = '' and v_firm = '' then
        continue;
      end if;

      v_parts := regexp_split_to_array(v_full_name, '\s+');
      v_person_type := case when v_side = 'buyer' then 'BUYER_SOLICITOR' else 'SELLER_SOLICITOR' end;
      v_row := jsonb_build_object(
        'transaction_id', v_submission.transaction_id,
        'person_type', v_person_type,
        'first_name', coalesce(v_parts[1], ''),
        'last_name', case when array_length(v_parts, 1) > 1 then array_to_string(v_parts[2:array_length(v_parts,1)], ' ') else '' end,
        'legal_name', nullif(v_full_name, ''),
        'company_name', nullif(v_firm, ''),
        'law_firm', nullif(v_firm, ''),
        'email', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_email'), '')), ''),
        'phone', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_phone'), '')), ''),
        'fax', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_fax'), '')), ''),
        'address', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_address'), '')), ''),
        'unit', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_unit'), '')), ''),
        'city', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_city'), '')), ''),
        'province', coalesce(nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_province'), '')), ''), 'ON'),
        'postal_code', nullif(trim(coalesce(v_submission.payload ->> (v_side || '_lawyer_postal_code'), '')), '')
      );

      select id into v_person_id
      from public.dv_accounting_transaction_people
      where transaction_id = v_submission.transaction_id
        and person_type = v_person_type
      order by created_at asc
      limit 1;

      if v_person_id is null then
        insert into public.dv_accounting_transaction_people (
          transaction_id, person_type, first_name, last_name, legal_name,
          company_name, law_firm, email, phone, fax, address, unit, city,
          province, postal_code
        )
        values (
          v_submission.transaction_id, v_person_type,
          v_row ->> 'first_name', v_row ->> 'last_name', v_row ->> 'legal_name',
          v_row ->> 'company_name', v_row ->> 'law_firm', v_row ->> 'email',
          v_row ->> 'phone', v_row ->> 'fax', v_row ->> 'address',
          v_row ->> 'unit', v_row ->> 'city', v_row ->> 'province',
          v_row ->> 'postal_code'
        );
      else
        update public.dv_accounting_transaction_people
        set first_name = v_row ->> 'first_name',
            last_name = v_row ->> 'last_name',
            legal_name = v_row ->> 'legal_name',
            company_name = v_row ->> 'company_name',
            law_firm = v_row ->> 'law_firm',
            email = v_row ->> 'email',
            phone = v_row ->> 'phone',
            fax = v_row ->> 'fax',
            address = v_row ->> 'address',
            unit = v_row ->> 'unit',
            city = v_row ->> 'city',
            province = v_row ->> 'province',
            postal_code = v_row ->> 'postal_code',
            updated_at = now()
        where id = v_person_id;
      end if;
      v_person_id := null;
    end loop;
  end loop;
end;
$$;
