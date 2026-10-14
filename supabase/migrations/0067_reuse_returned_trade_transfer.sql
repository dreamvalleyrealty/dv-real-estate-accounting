-- 0067: retain and reuse the prior draft transaction when returning a trade for correction.
create or replace function public.dv_accounting_return_agent_trade_transfer(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  c record;
  v_old_transaction_id uuid;
  v_review_notes text;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only a trade administrator can return an approved transfer';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Trade submission not found'; end if;
  if s.status <> 'APPROVED' then raise exception 'Only an approved trade can have its transfer returned'; end if;

  v_old_transaction_id := s.transaction_id;

  if v_old_transaction_id is not null then
    select * into t
    from public.dv_accounting_transactions
    where id = v_old_transaction_id
    for update;

    if not found then
      raise exception 'The linked accounting transaction could not be found. No changes were made.';
    end if;
    if upper(coalesce(t.status, 'DRAFT')) <> 'DRAFT' then
      raise exception 'This transfer cannot be returned because its accounting transaction is %. Only draft transfers can be returned here.', t.status;
    end if;
    if coalesce(t.ar_payment_received, false)
      or coalesce(t.ar_payment_amount, 0) > 0
      or coalesce(t.deposit_refunded, false)
      or upper(coalesce(t.commission_payroll_status, 'NOT_READY')) = 'PAID' then
      raise exception 'This transfer has a recorded receipt, deposit refund, or paid commission. Reverse that activity through the accounting workflow first.';
    end if;

    -- Posted trust receipts/liabilities and all draft transaction details remain
    -- on the same transaction ID. The record is retained as RETURNED history and
    -- reused on reapproval, so the trust money is never deleted or detached.

    for c in
      select id, status, paid_date
      from public.dv_accounting_commissions
      where transaction_id = v_old_transaction_id
      for update
    loop
      if upper(coalesce(c.status, '')) = 'RETURNED' then
        continue;
      end if;
      if upper(coalesce(c.status, '')) <> 'READY' or c.paid_date is not null then
        raise exception 'This transfer has a commission that is no longer in the unused READY state. Return or reverse that commission through Commission Payroll first.';
      end if;
      if exists (select 1 from public.dv_accounting_commission_charges x where x.commission_id = c.id)
        or exists (select 1 from public.dv_accounting_commission_cheques x where x.commission_id = c.id)
        or exists (select 1 from public.dv_accounting_commission_corrections x where x.commission_id = c.id) then
        raise exception 'This transfer has linked commission charges, cheques, or corrections. Reverse those records first.';
      end if;
      update public.dv_accounting_commissions
      set status = 'RETURNED'
      where id = c.id;
    end loop;

    update public.dv_accounting_transactions
    set status = 'RETURNED',
        commission_id = null,
        commission_approved = false,
        commission_approved_at = null,
        commission_approved_amount = null,
        commission_approved_agent_payable = null,
        commission_payroll_status = 'NOT_READY'
    where id = v_old_transaction_id;

    -- Keep every file in place; clear only the live transfer link on submission docs.
    update public.dv_accounting_agent_trade_documents
    set transaction_id = null
    where submission_id = s.id
      and transaction_id = v_old_transaction_id;
  end if;

  v_review_notes := concat_ws(E'\n',
    nullif(trim(coalesce(s.review_notes, '')), ''),
    'Transfer returned for editing by '
      || coalesce(auth.jwt()->>'email', 'administrator')
      || ' on ' || to_char(now(), 'YYYY-MM-DD HH24:MI')
      || '. Prior transaction details, trust entries, and archived documents are preserved; the same transaction will be reused on reapproval.'
  );

  update public.dv_accounting_agent_trade_submissions
  set status = 'SUBMITTED',
      transaction_id = v_old_transaction_id,
      review_notes = v_review_notes,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = s.id;

  return jsonb_build_object(
    'submission_id', s.id,
    'status', 'SUBMITTED',
    'transaction_id', v_old_transaction_id,
    'returned_transaction_id', v_old_transaction_id,
    'review_notes', v_review_notes
  );
end;
$$;

create or replace function public.dv_accounting_approve_agent_trade_submission(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  old_t public.dv_accounting_transactions%rowtype;
  p jsonb;
  new_tx_id uuid;
  v_person_id uuid;
  v_existing_commission_id uuid;
  buyer text;
  seller text;
  tx_no text;
  v_client_name text;
  v_property_address text;
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
  v_client_name := coalesce(
    nullif(trim(coalesce(p->>'client_name','')), ''),
    nullif(concat_ws(' / ', buyer, seller), '')
  );
  v_property_address := coalesce(
    nullif(trim(coalesce(p->>'property_address','')), ''),
    nullif(trim(concat_ws(', ',
      nullif(trim(coalesce(p->>'street_number','')), ''),
      nullif(trim(coalesce(p->>'street_name','')), ''),
      case when nullif(trim(coalesce(p->>'unit_number','')), '') is not null
        then 'Unit ' || trim(p->>'unit_number') else null end,
      nullif(trim(coalesce(p->>'city','')), ''),
      nullif(trim(coalesce(p->>'province','')), ''),
      nullif(trim(coalesce(p->>'postal_code','')), '')
    )), '')
  );

  if s.transaction_id is not null then
    -- The return operation preserves the original transaction and marks it
    -- RETURNED. Reuse that exact ID so deposits, trust liabilities and documents
    -- remain associated with the same transaction after editing.
    select * into old_t
    from public.dv_accounting_transactions
    where id = s.transaction_id
    for update;

    if not found then raise exception 'The returned transaction could not be found. No new transaction was created.'; end if;
    if upper(coalesce(old_t.status, '')) <> 'RETURNED' then
      raise exception 'This submission is linked to a transaction that is not marked RETURNED. No duplicate transaction was created.';
    end if;
    if coalesce(old_t.ar_payment_received, false)
      or coalesce(old_t.ar_payment_amount, 0) > 0
      or coalesce(old_t.deposit_refunded, false)
      or upper(coalesce(old_t.commission_payroll_status, 'NOT_READY')) = 'PAID' then
      raise exception 'The returned transaction now has a receipt, deposit refund, or paid commission. Resolve it before reapproving.';
    end if;
    if exists (select 1 from public.dv_accounting_commissions c where c.transaction_id = old_t.id and upper(coalesce(c.status,'')) not in ('RETURNED') ) then
      raise exception 'The returned commission is no longer in RETURNED status. Review Commission Payroll before reapproving.';
    end if;

    new_tx_id := old_t.id;
    tx_no := coalesce(
      nullif(trim(coalesce(p->>'transaction_number','')), ''),
      nullif(trim(coalesce(old_t.transaction_number,'')), ''),
      'AG-' || upper(substr(replace(s.id::text,'-',''),1,10))
    );

    select c.id into v_existing_commission_id
    from public.dv_accounting_commissions c
    where c.transaction_id = new_tx_id
      and upper(coalesce(c.status,'')) = 'RETURNED'
      and c.paid_date is null
    order by c.id
    limit 1;

    update public.dv_accounting_transactions
    set transaction_number = tx_no,
        status = 'DRAFT',
        transaction_date = nullif(p->>'transaction_date','')::date,
        property_address = v_property_address,
        client_name = v_client_name,
        side = nullif(trim(coalesce(p->>'side','')), ''),
        sale_price = coalesce(nullif(p->>'sale_price','')::numeric,0),
        gross_commission = coalesce(nullif(p->>'gross_commission','')::numeric,0),
        agent_id = s.agent_id,
        street_number = nullif(trim(coalesce(p->>'street_number','')), ''),
        street_name = nullif(trim(coalesce(p->>'street_name','')), ''),
        unit_number = nullif(trim(coalesce(p->>'unit_number','')), ''),
        city = nullif(trim(coalesce(p->>'city','')), ''),
        province = coalesce(nullif(trim(coalesce(p->>'province','')), ''), 'ON'),
        postal_code = nullif(trim(coalesce(p->>'postal_code','')), ''),
        offer_date = nullif(p->>'offer_date','')::date,
        firm_date = nullif(p->>'firm_date','')::date,
        close_date = nullif(p->>'close_date','')::date,
        mls_number = nullif(trim(coalesce(p->>'mls_number','')), ''),
        transaction_type = coalesce(nullif(trim(coalesce(p->>'transaction_type','')), ''), 'BUY_SELL'),
        commission_id = null,
        commission_approved = false,
        commission_approved_at = null,
        commission_approved_amount = null,
        commission_approved_agent_payable = null,
        commission_payroll_status = 'NOT_READY'
    where id = new_tx_id;

    if buyer is not null then
      select id into v_person_id
      from public.dv_accounting_transaction_people
      where transaction_id = new_tx_id and person_type = 'BUYER'
      order by created_at asc
      limit 1
      for update;
      if v_person_id is null then
        insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
        values(new_tx_id,'BUYER',split_part(buyer,' ',1),nullif(substr(buyer,length(split_part(buyer,' ',1))+2),''),nullif(p->>'buyer_company',''),nullif(p->>'buyer_email',''),nullif(p->>'buyer_phone',''));
      else
        update public.dv_accounting_transaction_people
        set first_name=split_part(buyer,' ',1),
            last_name=nullif(substr(buyer,length(split_part(buyer,' ',1))+2),''),
            company_name=nullif(p->>'buyer_company',''),
            email=nullif(p->>'buyer_email',''),
            phone=nullif(p->>'buyer_phone','')
        where id=v_person_id;
      end if;
    end if;

    if seller is not null then
      v_person_id := null;
      select id into v_person_id
      from public.dv_accounting_transaction_people
      where transaction_id = new_tx_id and person_type = 'SELLER'
      order by created_at asc
      limit 1
      for update;
      if v_person_id is null then
        insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
        values(new_tx_id,'SELLER',split_part(seller,' ',1),nullif(substr(seller,length(split_part(seller,' ',1))+2),''),nullif(p->>'seller_company',''),nullif(p->>'seller_email',''),nullif(p->>'seller_phone',''));
      else
        update public.dv_accounting_transaction_people
        set first_name=split_part(seller,' ',1),
            last_name=nullif(substr(seller,length(split_part(seller,' ',1))+2),''),
            company_name=nullif(p->>'seller_company',''),
            email=nullif(p->>'seller_email',''),
            phone=nullif(p->>'seller_phone','')
        where id=v_person_id;
      end if;
    end if;

  else
    tx_no := coalesce(nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));

    insert into public.dv_accounting_transactions (
      company_id, transaction_number, status, transaction_date, property_address,
      client_name, side, sale_price, gross_commission, agent_id,
      street_number, street_name, unit_number, city, province, postal_code,
      offer_date, firm_date, close_date, entry_date, mls_number, transaction_type
    )
    values (
      (select a.company_id from public.dv_accounting_agents a where a.id = s.agent_id limit 1),
      tx_no, 'DRAFT',
      nullif(p->>'transaction_date','')::date,
      v_property_address,
      v_client_name,
      nullif(trim(coalesce(p->>'side','')), ''),
      coalesce(nullif(p->>'sale_price','')::numeric,0),
      coalesce(nullif(p->>'gross_commission','')::numeric,0),
      s.agent_id,
      nullif(p->>'street_number',''), nullif(p->>'street_name',''), nullif(p->>'unit_number',''),
      nullif(p->>'city',''), coalesce(nullif(p->>'province',''),'ON'), nullif(p->>'postal_code',''),
      nullif(p->>'offer_date','')::date, nullif(p->>'firm_date','')::date, nullif(p->>'close_date','')::date,
      current_date, nullif(p->>'mls_number',''), coalesce(nullif(p->>'transaction_type',''),'BUY_SELL')
    )
    returning id into new_tx_id;

    if buyer is not null then
      insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
      values(new_tx_id,'BUYER',split_part(buyer,' ',1),nullif(substr(buyer,length(split_part(buyer,' ',1))+2),''),nullif(p->>'buyer_company',''),nullif(p->>'buyer_email',''),nullif(p->>'buyer_phone',''));
    end if;
    if seller is not null then
      insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
      values(new_tx_id,'SELLER',split_part(seller,' ',1),nullif(substr(seller,length(split_part(seller,' ',1))+2),''),nullif(p->>'seller_company',''),nullif(p->>'seller_email',''),nullif(p->>'seller_phone',''));
    end if;
  end if;

  update public.dv_accounting_agent_trade_documents
  set transaction_id = new_tx_id
  where submission_id = s.id;

  update public.dv_accounting_agent_trade_submissions
  set status = 'APPROVED',
      transaction_id = new_tx_id,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = s.id;

  return new_tx_id;
end;
$$;

revoke all on function public.dv_accounting_return_agent_trade_transfer(uuid) from public, anon;
grant execute on function public.dv_accounting_return_agent_trade_transfer(uuid) to authenticated;
revoke all on function public.dv_accounting_approve_agent_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_approve_agent_trade_submission(uuid) to authenticated;
