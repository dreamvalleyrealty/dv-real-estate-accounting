-- Create/link the accounting transaction as soon as Trade Admin sends a submission back for changes.
-- Approval reuses the same linked DRAFT transaction, avoiding duplicate transactions.
create or replace function public.dv_accounting_ensure_agent_trade_transaction(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  p jsonb;
  v_tx_id uuid;
  v_tx_no text;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only a trade administrator can create or update the linked transaction';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Trade submission not found'; end if;
  p := coalesce(s.payload, '{}'::jsonb);
  v_tx_no := coalesce(nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));
  v_tx_id := s.transaction_id;

  if v_tx_id is not null then
    select * into t from public.dv_accounting_transactions where id = v_tx_id for update;
    if found then
      if upper(coalesce(t.status,'DRAFT')) <> 'DRAFT' then
        -- Do not silently rewrite a transaction once accounting has moved it beyond DRAFT.
        return v_tx_id;
      end if;

      update public.dv_accounting_transactions
      set transaction_number = v_tx_no,
          transaction_date = nullif(p->>'transaction_date','')::date,
          property_address = nullif(trim(coalesce(p->>'property_address','')),''),
          client_name = nullif(trim(coalesce(p->>'client_name',p->>'buyer_name',p->>'seller_name','')),''),
          side = nullif(trim(coalesce(p->>'side','')),''),
          sale_price = coalesce(nullif(p->>'sale_price','')::numeric,0),
          gross_commission = coalesce(nullif(p->>'gross_commission','')::numeric,0),
          street_number = nullif(p->>'street_number',''),
          street_name = nullif(p->>'street_name',''),
          unit_number = nullif(p->>'unit_number',''),
          city = nullif(p->>'city',''),
          province = coalesce(nullif(p->>'province',''),'ON'),
          postal_code = nullif(p->>'postal_code',''),
          offer_date = nullif(p->>'offer_date','')::date,
          firm_date = nullif(p->>'firm_date','')::date,
          close_date = nullif(p->>'close_date','')::date,
          mls_number = nullif(p->>'mls_number',''),
          transaction_type = coalesce(nullif(p->>'transaction_type',''),'BUY_SELL')
      where id = v_tx_id;
      return v_tx_id;
    end if;
  end if;

  insert into public.dv_accounting_transactions (
    company_id, transaction_number, status, transaction_date, property_address,
    client_name, side, sale_price, gross_commission, agent_id,
    street_number, street_name, unit_number, city, province, postal_code,
    offer_date, firm_date, close_date, entry_date, mls_number, transaction_type
  )
  values (
    (select a.company_id from public.dv_accounting_agents a where a.id = s.agent_id limit 1),
    v_tx_no, 'DRAFT',
    nullif(p->>'transaction_date','')::date,
    nullif(trim(coalesce(p->>'property_address','')),''),
    nullif(trim(coalesce(p->>'client_name',p->>'buyer_name',p->>'seller_name','')),''),
    nullif(trim(coalesce(p->>'side','')),''),
    coalesce(nullif(p->>'sale_price','')::numeric,0),
    coalesce(nullif(p->>'gross_commission','')::numeric,0),
    s.agent_id,
    nullif(p->>'street_number',''), nullif(p->>'street_name',''), nullif(p->>'unit_number',''),
    nullif(p->>'city',''), coalesce(nullif(p->>'province',''),'ON'), nullif(p->>'postal_code',''),
    nullif(p->>'offer_date','')::date, nullif(p->>'firm_date','')::date, nullif(p->>'close_date','')::date,
    current_date, nullif(p->>'mls_number',''), coalesce(nullif(p->>'transaction_type',''),'BUY_SELL')
  )
  returning id into v_tx_id;

  if nullif(trim(coalesce(p->>'buyer_name','')), '') is not null then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(v_tx_id,'BUYER',split_part(trim(p->>'buyer_name'),' ',1),
      nullif(substr(trim(p->>'buyer_name'),length(split_part(trim(p->>'buyer_name'),' ',1))+2),''),
      nullif(p->>'buyer_company',''),nullif(p->>'buyer_email',''),nullif(p->>'buyer_phone',''));
  end if;
  if nullif(trim(coalesce(p->>'seller_name','')), '') is not null then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(v_tx_id,'SELLER',split_part(trim(p->>'seller_name'),' ',1),
      nullif(substr(trim(p->>'seller_name'),length(split_part(trim(p->>'seller_name'),' ',1))+2),''),
      nullif(p->>'seller_company',''),nullif(p->>'seller_email',''),nullif(p->>'seller_phone',''));
  end if;

  update public.dv_accounting_agent_trade_submissions
  set transaction_id = v_tx_id, updated_at = now()
  where id = s.id;
  return v_tx_id;
end;
$$;

revoke all on function public.dv_accounting_ensure_agent_trade_transaction(uuid) from public, anon;
grant execute on function public.dv_accounting_ensure_agent_trade_transaction(uuid) to authenticated;

create or replace function public.dv_accounting_approve_agent_trade_submission(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  v_tx_id uuid;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only the Trade Admin Manager or an administrator can approve trade submissions';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Trade submission not found'; end if;
  if s.status = 'APPROVED' and s.transaction_id is not null then return s.transaction_id; end if;
  if s.status <> 'SUBMITTED' then raise exception 'Only submitted trades can be approved'; end if;

  if exists (
    select 1 from public.dv_accounting_agent_trade_documents d
    where d.submission_id = s.id and d.match_status <> 'MATCH'
  ) or not exists (
    select 1 from public.dv_accounting_agent_trade_documents d where d.submission_id = s.id
  ) then
    raise exception 'At least one document is required and every document must be approved before the trade can be approved';
  end if;

  v_tx_id := public.dv_accounting_ensure_agent_trade_transaction(s.id);

  update public.dv_accounting_agent_trade_submissions
  set status = 'APPROVED', transaction_id = v_tx_id,
      reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = s.id;

  return v_tx_id;
end;
$$;

revoke all on function public.dv_accounting_approve_agent_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_approve_agent_trade_submission(uuid) to authenticated;

create or replace function public.dv_accounting_review_agent_trade_submission(p_submission_id uuid, p_status text, p_notes text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  v_tx_id uuid;
begin
  if not public.dv_accounting_is_trade_admin() then raise exception 'Only the Trade Admin Manager or an administrator can review submissions'; end if;
  if p_status not in ('NEEDS_CHANGES','SUBMITTED') then raise exception 'Invalid review status'; end if;

  select * into s from public.dv_accounting_agent_trade_submissions where id=p_submission_id for update;
  if not found or s.status <> 'SUBMITTED' then raise exception 'Submission not found or no longer awaiting review'; end if;

  if p_status = 'NEEDS_CHANGES' then
    -- Create the accounting draft immediately, while the agent is correcting documents/details.
    v_tx_id := public.dv_accounting_ensure_agent_trade_transaction(s.id);
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status=p_status, review_notes=nullif(trim(coalesce(p_notes,'')),''),
      reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where id=s.id;
end;
$$;

revoke all on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) from public, anon;
grant execute on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) to authenticated;
