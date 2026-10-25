-- Listing-side trust accounting: suppress AR at finalization and recognize commission only on transfer.
-- Buyer-side and other transaction types retain their existing AR/revenue posting.

create or replace function public.dv_accounting_finalize_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 t public.dv_accounting_transactions%rowtype;
 company uuid;
 je uuid;
 ar uuid; rev uuid; hst uuid; agent_exp uuid; agent_pay uuid;
 coop_exp uuid; coop_pay uuid; hst_rec uuid; trust_bank_gl uuid; trust_liability uuid;
 agent_amt numeric(14,2);
 c record;
 tr record;
 coop_hst numeric(14,2);
 listing_side boolean := false;
begin
 select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if t.status='FINALIZED' then return jsonb_build_object('ok',true,'message','Already finalized'); end if;
 company:=t.company_id;
 listing_side := upper(coalesce(t.side,'')) in ('SELLER','LANDLORD','LISTING')
   and (coalesce(t.is_own_listing,false) or t.listing_id is not null);
 if company is null then
   select id into company from public.dv_accounting_companies order by created_at limit 1;
   if company is null then raise exception 'Create a company in Settings before finalizing transactions'; end if;
   update public.dv_accounting_transactions set company_id=company where id=t.id;
 end if;

 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values
 (company,'1150','Commission Receivable','ASSET'),
 (company,'4000','Commission Revenue','REVENUE'),
 (company,'2400','HST Payable','LIABILITY'),
 (company,'5200','Agent Commission Expense','EXPENSE'),
 (company,'2200','Agent Commissions Payable','LIABILITY'),
 (company,'2100','Co-operating Brokerage Payable','LIABILITY'),
 (company,'5250','Co-operating Brokerage Commission Expense','EXPENSE'),
 (company,'1180','HST Recoverable / Input Tax Credits','ASSET'),
 (company,'1015','Real Estate Trust Bank','ASSET'),
 (company,'2300','Real Estate Trust Liabilities','LIABILITY')
 on conflict(company_id,code) do nothing;

 select id into ar from public.dv_accounting_gl_accounts where company_id=company and code='1150';
 select id into rev from public.dv_accounting_gl_accounts where company_id=company and code='4000';
 select id into hst from public.dv_accounting_gl_accounts where company_id=company and code='2400';
 select id into agent_exp from public.dv_accounting_gl_accounts where company_id=company and code='5200';
 select id into agent_pay from public.dv_accounting_gl_accounts where company_id=company and code='2200';
 select id into coop_exp from public.dv_accounting_gl_accounts where company_id=company and code='5250';
 select id into coop_pay from public.dv_accounting_gl_accounts where company_id=company and code='2100';
 select id into hst_rec from public.dv_accounting_gl_accounts where company_id=company and code='1180';
 select id into trust_bank_gl from public.dv_accounting_gl_accounts where company_id=company and code='1015';
 select id into trust_liability from public.dv_accounting_gl_accounts where company_id=company and code='2300';

 agent_amt:=coalesce(t.agent_commission,0);
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(company,coalesce(t.close_date,t.transaction_date,current_date),'TRANSACTION',t.id,'Finalize real estate transaction') returning id into je;

 -- Brokerage commission receivable and revenue, plus HST collected.
 if not listing_side and (coalesce(t.gross_commission,0)<>0 or coalesce(t.hst_amount,0)<>0) then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,ar,coalesce(t.gross_commission,0)+coalesce(t.hst_amount,0),0),
         (je,rev,0,coalesce(t.gross_commission,0));
   if coalesce(t.hst_amount,0)<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,hst,0,t.hst_amount);
   end if;
 end if;

 -- Agent commission expense and amount due to the agent.
 if agent_amt<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,agent_exp,agent_amt,0),(je,agent_pay,0,agent_amt);
 end if;

 -- Co-operating brokerage commissions: expense + any eligible HST ITC, offset by A/P.
 for c in
   select tc.*, coalesce(eb.charges_hst,true) as brokerage_charges_hst
   from public.dv_accounting_transaction_commissions tc
   left join public.dv_accounting_external_brokerages eb on eb.id=tc.brokerage_id
   where tc.transaction_id=t.id and tc.settlement_direction='PAYABLE'
 loop
   coop_hst:=case when c.brokerage_charges_hst then coalesce(c.hst_amount,0) else 0 end;
   if coalesce(c.amount,0)+coop_hst<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_exp,coalesce(c.amount,0),0);
     if coop_hst<>0 then
       insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
       values(je,hst_rec,coop_hst,0);
     end if;
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_pay,0,coalesce(c.amount,0)+coop_hst);
   end if;
 end loop;

 -- Only post a trust receipt when Dream Valley actually holds and has received the deposit.
 select * into tr
 from public.dv_accounting_transaction_trust
 where transaction_id=t.id and we_hold_deposit='YES' and received='YES' and amount>0
 order by created_at desc limit 1;
 if found then
   if tr.trust_bank_account_id is null then
     raise exception 'Select the Real Estate Trust bank account before finalizing a received deposit';
   end if;
   if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=tr.trust_bank_account_id and b.account_type='REAL_ESTATE_TRUST' and b.active=true) then
     raise exception 'The selected deposit account must be an active Real Estate Trust account';
   end if;
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,trust_bank_gl,tr.amount,0),(je,trust_liability,0,tr.amount);
 end if;

 update public.dv_accounting_transactions
 set status='FINALIZED', finalized_at=now(), finalized_date=coalesce(finalized_date,current_date), company_id=company
 where id=t.id;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'agent_commission',agent_amt);
end $$;

revoke all on function public.dv_accounting_finalize_transaction(uuid) from public;
grant execute on function public.dv_accounting_finalize_transaction(uuid) to authenticated;

create or replace function public.dv_accounting_process_seller_commission_transfer(
  p_settlement_id uuid,
  p_transfer_reference text,
  p_transfer_date date
)
returns public.dv_accounting_seller_settlements
language plpgsql
set search_path = public
as $$
declare
  v public.dv_accounting_seller_settlements%rowtype;
  v_total numeric(14,2);
  v_available numeric(14,2);
begin
  select * into v
  from public.dv_accounting_seller_settlements
  where id = p_settlement_id
  for update;

  if not found then
    raise exception 'Seller settlement was not found.';
  end if;

  if v.status not in ('SELLER_PROCEEDS_CALCULATED','SELLER_PAID') then
    raise exception 'Save and verify the seller settlement before transferring commissions.';
  end if;

  if coalesce(v.deposit_held_amount, 0) + 0.005 < coalesce(v.listing_commission_amount, 0) + coalesce(v.cooperating_commission_amount, 0) + coalesce(v.commission_hst_amount, 0) then
    raise exception 'The held trust deposit is insufficient to fund the full commission transfer.';
  end if;

  if v.real_estate_trust_account_id is null
     or v.commission_trust_account_id is null
     or v.real_estate_trust_account_id = v.commission_trust_account_id then
    raise exception 'Select two different trust accounts.';
  end if;

  if coalesce(nullif(trim(v.seller_client_name), ''), '') = ''
     or coalesce(nullif(trim(v.matter), ''), '') = '' then
    raise exception 'Seller/client name and trade number are required for the trust ledger.';
  end if;

  v_total := round(
    coalesce(v.listing_commission_amount, 0)
    + coalesce(v.cooperating_commission_amount, 0)
    + coalesce(v.commission_hst_amount, 0), 2
  );

  if v_total <= 0 then
    raise exception 'Commission transfer must be greater than zero.';
  end if;

  if coalesce(nullif(trim(p_transfer_reference), ''), '') = '' or p_transfer_date is null then
    raise exception 'Transfer reference and date are required.';
  end if;

  if not exists (
    select 1 from public.dv_accounting_bank_accounts
    where id = v.real_estate_trust_account_id and company_id = v.company_id and account_type = 'REAL_ESTATE_TRUST'
  ) then
    raise exception 'The selected Real Estate Trust account does not belong to this company.';
  end if;
  if not exists (
    select 1 from public.dv_accounting_bank_accounts
    where id = v.commission_trust_account_id and company_id = v.company_id and account_type = 'COMMISSION_TRUST'
  ) then
    raise exception 'The selected Commission Trust account does not belong to this company.';
  end if;
  select coalesce(ba.opening_balance, 0) + coalesce(sum(bt.amount), 0) into v_available
  from public.dv_accounting_bank_accounts ba
  left join public.dv_accounting_bank_transactions bt on bt.bank_account_id = ba.id
  where ba.id = v.real_estate_trust_account_id and ba.company_id = v.company_id
  group by ba.id, ba.opening_balance;
  if not found or coalesce(v_available, 0) + 0.005 < v_total then
    raise exception 'Insufficient available Real Estate Trust bank balance for the commission transfer.';
  end if;

  -- Both ledger posts occur in this database transaction. If either post fails,
  -- PostgreSQL rolls back both, preventing one-sided trust transfers.
  perform public.dv_accounting_post_trust_transaction(
    p_company_id => v.company_id,
    p_bank_account_id => v.real_estate_trust_account_id,
    p_transaction_id => v.transaction_id,
    p_ledger_date => p_transfer_date,
    p_trust_account_type => 'REAL_ESTATE_TRUST',
    p_direction => 'DISBURSEMENT',
    p_client_name => v.seller_client_name,
    p_matter => v.matter,
    p_description => 'Commission transfer to Commission Trust - ' || v.matter,
    p_amount => v_total,
    p_reference => trim(p_transfer_reference) || '-OUT'
  );

  perform public.dv_accounting_post_trust_transaction(
    p_company_id => v.company_id,
    p_bank_account_id => v.commission_trust_account_id,
    p_transaction_id => v.transaction_id,
    p_ledger_date => p_transfer_date,
    p_trust_account_type => 'COMMISSION_TRUST',
    p_direction => 'DEPOSIT',
    p_client_name => v.seller_client_name,
    p_matter => v.matter,
    p_description => 'Commission transfer received from Real Estate Trust - ' || v.matter,
    p_amount => v_total,
    p_reference => trim(p_transfer_reference) || '-IN'
  );

  -- Listing-side commission revenue is recognized only when the funds are transferred
  -- from Real Estate Trust to Commission Trust. Debit the trust liability and credit
  -- commission revenue and HST payable; this journal is balanced and is atomic with both
  -- trust ledger movements below.
  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
  values (v.company_id,'4000','Commission Revenue','REVENUE'),
         (v.company_id,'2400','HST Payable','LIABILITY'),
         (v.company_id,'2300','Real Estate Trust Liabilities','LIABILITY')
  on conflict(company_id,code) do nothing;
  declare
    v_rev_gl uuid;
    v_hst_gl uuid;
    v_trust_liability_gl uuid;
    v_journal_id uuid;
    v_revenue_amount numeric(14,2);
  begin
    select id into v_rev_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='4000';
    select id into v_hst_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2400';
    select id into v_trust_liability_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2300';
    v_revenue_amount := round(coalesce(v.listing_commission_amount,0)+coalesce(v.cooperating_commission_amount,0),2);
    insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
    values(v.company_id,p_transfer_date,'SELLER_COMMISSION_TRANSFER',v.id,'Recognize listing-side commission on trust transfer')
    returning id into v_journal_id;
    insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    values(v_journal_id,v_trust_liability_gl, v_total,0);
    if v_revenue_amount > 0 then
      insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      values(v_journal_id,v_rev_gl,0,v_revenue_amount);
    end if;
    if coalesce(v.commission_hst_amount,0) > 0 then
      insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      values(v_journal_id,v_hst_gl,0,round(v.commission_hst_amount,2));
    end if;
  end;

  update public.dv_accounting_seller_settlements
  set status = 'READY_FOR_COMMISSION_PAYROLL',
      commission_transfer_amount = v_total,
      commission_transfer_reference = trim(p_transfer_reference),
      commission_transfer_date = p_transfer_date,
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_settlement_id
  returning * into v;

  return v;
end;
$$;

-- Retain an explicit payment-direction record on the settlement for signed authorization.
alter table public.dv_accounting_seller_settlements
  add column if not exists authorized_payee_name text,
  add column if not exists authorized_payee_type text,
  add column if not exists payment_direction_storage_path text,
  add column if not exists payment_direction_file_name text,
  add column if not exists payment_direction_received_at timestamptz,
  add column if not exists seller_payment_method text,
  add column if not exists seller_payment_status text not null default 'PENDING',
  add column if not exists seller_payment_audit jsonb not null default '[]'::jsonb;

alter table public.dv_accounting_seller_settlements
  drop constraint if exists dv_accounting_seller_settlements_authorized_payee_type_check;
alter table public.dv_accounting_seller_settlements
  add constraint dv_accounting_seller_settlements_authorized_payee_type_check
  check (authorized_payee_type is null or authorized_payee_type in ('SELLER','LANDLORD','LAWYER','THIRD_PARTY'));

alter table public.dv_accounting_seller_settlements
  drop constraint if exists dv_accounting_seller_settlements_seller_payment_method_check;
alter table public.dv_accounting_seller_settlements
  add constraint dv_accounting_seller_settlements_seller_payment_method_check
  check (seller_payment_method is null or seller_payment_method in ('CHEQUE','EFT','WIRE','OTHER'));

alter table public.dv_accounting_seller_settlements
  drop constraint if exists dv_accounting_seller_settlements_seller_payment_status_check;
alter table public.dv_accounting_seller_settlements
  add constraint dv_accounting_seller_settlements_seller_payment_status_check
  check (seller_payment_status in ('PENDING','DIRECTION_RECEIVED','PROCESSED','COMPLETED'));

create table if not exists public.dv_accounting_seller_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id),
  settlement_id uuid not null references public.dv_accounting_seller_settlements(id),
  transaction_id uuid not null references public.dv_accounting_transactions(id),
  payee_name text not null,
  payee_type text not null check (payee_type in ('SELLER','LANDLORD','LAWYER','THIRD_PARTY')),
  amount numeric(14,2) not null check (amount > 0),
  payment_date date,
  payment_method text check (payment_method is null or payment_method in ('CHEQUE','EFT','WIRE','OTHER')),
  reference text,
  status text not null default 'PENDING' check (status in ('PENDING','DIRECTION_RECEIVED','PROCESSED','COMPLETED')),
  direction_storage_path text,
  direction_file_name text,
  supporting_document_paths jsonb not null default '[]'::jsonb,
  trust_transaction_id uuid references public.dv_accounting_trust_transactions(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid,
  completed_at timestamptz,
  unique(settlement_id, reference)
);

create index if not exists dv_accounting_seller_settlement_payments_settlement_idx
  on public.dv_accounting_seller_settlement_payments(settlement_id, status);

alter table public.dv_accounting_seller_settlement_payments enable row level security;
drop policy if exists "Seller settlement payments administrators" on public.dv_accounting_seller_settlement_payments;
create policy "Seller settlement payments administrators"
  on public.dv_accounting_seller_settlement_payments for all to authenticated
  using (upper(coalesce(auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','')) in ('SUPERADMIN','ADMIN'))
  with check (upper(coalesce(auth.jwt()->'app_metadata'->>'role',auth.jwt()->'user_metadata'->>'role','')) in ('SUPERADMIN','ADMIN'));

create or replace function public.dv_accounting_validate_seller_settlement_payment()
returns trigger language plpgsql set search_path=public as $$
declare
  v_settlement public.dv_accounting_seller_settlements%rowtype;
  v_total numeric(14,2);
  v_posted numeric(14,2);
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  select * into v_settlement from public.dv_accounting_seller_settlements where id=new.settlement_id for update;
  if not found then raise exception 'Seller settlement was not found.'; end if;
  if new.company_id is distinct from v_settlement.company_id or new.transaction_id is distinct from v_settlement.transaction_id then
    raise exception 'Payment must belong to the settlement transaction and company.';
  end if;
  if new.status in ('PROCESSED','COMPLETED') then
    if coalesce(nullif(trim(new.reference),''),'')='' or new.payment_date is null or new.payment_method is null then
      raise exception 'Payment date, method and reference are required before processing.';
    end if;
    if new.direction_storage_path is not null and new.status='COMPLETED' and new.trust_transaction_id is null then
      raise exception 'A payment direction does not complete payment. Record the actual trust disbursement before marking it completed.';
    end if;
  end if;
  if new.status='COMPLETED' and new.trust_transaction_id is null then
    raise exception 'Payment cannot be completed until the actual trust disbursement is posted.';
  end if;
  select coalesce(sum(amount),0) into v_total from public.dv_accounting_seller_settlement_payments
    where settlement_id=new.settlement_id and id<>new.id and status in ('PROCESSED','COMPLETED');
  if new.status in ('PROCESSED','COMPLETED') then v_total:=v_total+new.amount; end if;
  if v_total > greatest(0,coalesce(v_settlement.deposit_held_amount,0)-coalesce(v_settlement.listing_commission_amount,0)-coalesce(v_settlement.cooperating_commission_amount,0)-coalesce(v_settlement.commission_hst_amount,0))+0.005 then
    raise exception 'Seller/landlord payments exceed the net proceeds available after commission.';
  end if;
  if new.trust_transaction_id is not null then
    if not exists(select 1 from public.dv_accounting_trust_transactions tt where tt.id=new.trust_transaction_id and tt.transaction_id=new.transaction_id and tt.direction='DISBURSEMENT' and tt.trust_account_type='REAL_ESTATE_TRUST' and tt.status='POSTED' and tt.amount=new.amount and tt.reference=new.reference) then
      raise exception 'Linked trust disbursement does not match this payment.';
    end if;
  end if;
  if tg_op='UPDATE' and old.status='COMPLETED' and (new.amount is distinct from old.amount or new.payee_name is distinct from old.payee_name or new.reference is distinct from old.reference or new.trust_transaction_id is distinct from old.trust_transaction_id) then
    raise exception 'Completed seller payments are locked; use an authorized accounting correction.';
  end if;
  return new;
end $$;

drop trigger if exists dv_accounting_validate_seller_settlement_payment on public.dv_accounting_seller_settlement_payments;
create trigger dv_accounting_validate_seller_settlement_payment before insert or update on public.dv_accounting_seller_settlement_payments
for each row execute function public.dv_accounting_validate_seller_settlement_payment();

create or replace function public.dv_accounting_post_listing_seller_payment(p_payment_id uuid)
returns public.dv_accounting_seller_settlement_payments
language plpgsql security definer set search_path=public as $$
declare
  p public.dv_accounting_seller_settlement_payments%rowtype;
  s public.dv_accounting_seller_settlements%rowtype;
  v_client text;
  v_posted_id uuid;
begin
  select * into p from public.dv_accounting_seller_settlement_payments where id=p_payment_id for update;
  if not found then raise exception 'Seller payment record was not found.'; end if;
  select * into s from public.dv_accounting_seller_settlements where id=p.settlement_id for update;
  if not found then raise exception 'Seller settlement was not found.'; end if;
  if p.status not in ('PROCESSED','COMPLETED') then raise exception 'Save the payment details and process the payment before posting the disbursement.'; end if;
  if p.direction_storage_path is not null and coalesce(trim(p.payee_name),'')='' then raise exception 'Authorized payee is required.'; end if;
  if p.payment_date is null or coalesce(trim(p.reference),'')='' or p.payment_method is null then raise exception 'Payment date, method and reference are required.'; end if;
  if p.trust_transaction_id is not null then return p; end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts ba where ba.id=s.real_estate_trust_account_id and ba.company_id=s.company_id and ba.account_type='REAL_ESTATE_TRUST' and ba.active=true) then
    raise exception 'Select an active Real Estate Trust account for this settlement.';
  end if;
  select l.client_name into v_client from public.dv_accounting_trust_liabilities l
    where l.company_id=s.company_id and l.trust_account_type='REAL_ESTATE_TRUST' and l.matter=s.matter and l.direction='RECEIVABLE' and l.amount>0 order by l.created_at limit 1;
  if coalesce(trim(v_client),'')='' then raise exception 'Cannot identify the original trust deposit client for this transaction.'; end if;
  perform public.dv_accounting_post_trust_transaction(
    s.company_id,s.real_estate_trust_account_id,s.transaction_id,p.payment_date,'REAL_ESTATE_TRUST','DISBURSEMENT',
    v_client,s.matter,'Seller/landlord payment to '||p.payee_name||' - '||s.matter,p.amount,p.reference
  );
  select id into v_posted_id from public.dv_accounting_trust_transactions
    where transaction_id=s.transaction_id and bank_account_id=s.real_estate_trust_account_id and trust_account_type='REAL_ESTATE_TRUST'
      and direction='DISBURSEMENT' and matter=s.matter and reference=p.reference and amount=p.amount and status='POSTED'
    order by created_at desc limit 1;
  if v_posted_id is null then raise exception 'Trust disbursement did not post.'; end if;
  update public.dv_accounting_seller_settlement_payments set trust_transaction_id=v_posted_id,status='COMPLETED',completed_at=now(),updated_at=now(),updated_by=auth.uid()
    where id=p.id returning * into p;
  update public.dv_accounting_seller_settlements set seller_paid_amount=coalesce(seller_paid_amount,0)+p.amount,
    seller_payment_status='COMPLETED',seller_payment_reference=p.reference,seller_payment_date=p.payment_date,seller_payment_method=p.payment_method,
    seller_payment_audit=coalesce(seller_payment_audit,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('event','PAYMENT_COMPLETED','payment_id',p.id,'amount',p.amount,'payee',p.payee_name,'reference',p.reference,'at',now(),'by',auth.uid())),
    updated_at=now(),updated_by=auth.uid() where id=s.id;
  return p;
end $$;

grant execute on function public.dv_accounting_post_listing_seller_payment(uuid) to authenticated;
