-- Allow administrators to approve trades that are either awaiting review or have changes requested.
-- The UI and RPC must agree: NEEDS_CHANGES remains eligible for an admin override.
create or replace function public.dv_accounting_approve_agent_trade_submission(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions;
  p jsonb;
  new_tx_id uuid;
  buyer text;
  seller text;
  tx_no text;
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
  if s.status not in ('SUBMITTED','NEEDS_CHANGES') then
    raise exception 'Only submitted or change-requested trades can be approved';
  end if;

  p := s.payload;
  buyer := nullif(trim(coalesce(p->>'buyer_name','')), '');
  seller := nullif(trim(coalesce(p->>'seller_name','')), '');
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
    nullif(trim(coalesce(p->>'property_address','')),''),
    nullif(trim(coalesce(p->>'client_name','')),''),
    nullif(trim(coalesce(p->>'side','')),''),
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

  update public.dv_accounting_agent_trade_submissions
  set status='APPROVED', transaction_id=new_tx_id, review_notes=null, reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where id=s.id;

  return new_tx_id;
end;
$$;

revoke all on function public.dv_accounting_approve_agent_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_approve_agent_trade_submission(uuid) to authenticated;
