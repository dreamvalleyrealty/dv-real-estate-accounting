-- Brokerage bulk payments: one Operating deposit backed by itemized Commission Trust releases.
create table if not exists public.dv_accounting_brokerage_payment_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id),
  source_bank_account_id uuid not null references public.dv_accounting_bank_accounts(id),
  destination_bank_account_id uuid not null references public.dv_accounting_bank_accounts(id),
  payment_date date not null,
  payment_reference text not null,
  total_amount numeric(14,2) not null check (total_amount > 0),
  trade_count integer not null check (trade_count > 0),
  status text not null default 'POSTED' check (status in ('POSTED','VOIDED')),
  created_by uuid,
  created_at timestamptz not null default now(),
  unique(company_id,payment_reference)
);
create table if not exists public.dv_accounting_brokerage_payment_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  company_id uuid not null references public.dv_accounting_companies(id),
  commission_id uuid not null references public.dv_accounting_commissions(id),
  transaction_id uuid not null references public.dv_accounting_transactions(id),
  trust_transaction_id uuid not null references public.dv_accounting_trust_transactions(id),
  brokerage_amount numeric(14,2) not null check (brokerage_amount >= 0),
  brokerage_hst_amount numeric(14,2) not null default 0 check (brokerage_hst_amount >= 0),
  total_amount numeric(14,2) not null check (total_amount > 0),
  created_at timestamptz not null default now(),
  unique(commission_id),
  constraint dv_accounting_brokerage_payment_items_batch_id_fkey
    foreign key(batch_id) references public.dv_accounting_brokerage_payment_batches(id)
    deferrable initially deferred
);
alter table public.dv_accounting_brokerage_payment_batches enable row level security;
alter table public.dv_accounting_brokerage_payment_items enable row level security;
drop policy if exists dv_brokerage_batch_select on public.dv_accounting_brokerage_payment_batches;
create policy dv_brokerage_batch_select on public.dv_accounting_brokerage_payment_batches
 for select to authenticated using (public.dv_accounting_has_permission_all_scope('commission.view') or public.dv_accounting_has_permission_all_scope('commission.issue'));
drop policy if exists dv_brokerage_item_select on public.dv_accounting_brokerage_payment_items;
create policy dv_brokerage_item_select on public.dv_accounting_brokerage_payment_items
 for select to authenticated using (public.dv_accounting_has_permission_all_scope('commission.view') or public.dv_accounting_has_permission_all_scope('commission.issue'));
grant select on public.dv_accounting_brokerage_payment_batches,public.dv_accounting_brokerage_payment_items to authenticated;
create index if not exists idx_dv_brokerage_payment_items_batch_id on public.dv_accounting_brokerage_payment_items(batch_id);
create index if not exists idx_dv_brokerage_payment_items_transaction_id on public.dv_accounting_brokerage_payment_items(transaction_id);
create index if not exists idx_dv_brokerage_payment_batches_company_date on public.dv_accounting_brokerage_payment_batches(company_id,payment_date desc);

create or replace function public.dv_accounting_issue_brokerage_bulk_payment(
 p_commission_ids uuid[],p_operating_account_id uuid,p_payment_reference text,p_payment_date date
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_commission record; v_batch_id uuid:=gen_random_uuid(); v_company_id uuid; v_source_account_id uuid;
 v_available_liability numeric(14,2); v_source_balance numeric(14,2); v_total numeric(14,2):=0;
 v_item_amount numeric(14,2); v_brokerage_amount numeric(14,2); v_brokerage_hst numeric(14,2);
 v_trust_result jsonb; v_trust_id uuid; v_count integer:=0; v_items jsonb:='[]'::jsonb;
begin
 if auth.uid() is null or not public.dv_accounting_has_permission_all_scope('commission.issue')
  or not public.dv_accounting_has_permission_all_scope('banking.reconcile') then
  raise exception 'You do not have permission to issue a brokerage bulk payment.';
 end if;
 if coalesce(array_length(p_commission_ids,1),0)<1 or array_length(p_commission_ids,1)>100 then
  raise exception 'Select between 1 and 100 eligible trades.';
 end if;
 if nullif(trim(coalesce(p_payment_reference,'')),'') is null or p_payment_date is null then
  raise exception 'Payment reference and date are required.';
 end if;
 if cardinality(p_commission_ids)<>(select count(distinct x) from unnest(p_commission_ids) x) then
  raise exception 'The selection contains duplicate trades.';
 end if;
 if not exists(select 1 from public.dv_accounting_bank_accounts where id=p_operating_account_id and account_type='OPERATING' and active=true) then
  raise exception 'Select an active Operating bank account.';
 end if;
 for v_commission in
  select c.id commission_id,c.transaction_id,c.status commission_status,c.gross_commission,c.brokerage_share,
   t.company_id,t.transaction_number,t.status transaction_status,ch.brokerage_hst_amount,
   dep.bank_account_id source_account_id,dep.client_name,dep.matter
  from public.dv_accounting_commissions c
  join public.dv_accounting_transactions t on t.id=c.transaction_id
  join lateral (select x.brokerage_hst_amount from public.dv_accounting_commission_cheques x
   where x.commission_id=c.id and upper(coalesce(x.status,''))='ISSUED'
   order by x.issued_at desc nulls last,x.created_at desc limit 1) ch on true
  join lateral (select x.bank_account_id,x.client_name,x.matter from public.dv_accounting_trust_transactions x
   where x.transaction_id=t.id and x.trust_account_type='COMMISSION_TRUST'
    and x.direction='DEPOSIT' and x.status='POSTED' order by x.created_at desc limit 1) dep on true
  where c.id=any(p_commission_ids) order by t.transaction_number for update of c
 loop
  if upper(coalesce(v_commission.commission_status,''))<>'PAID' then
   raise exception 'Commission for trade % must be paid/issued to the agent first.',v_commission.transaction_number;
  end if;
  if upper(coalesce(v_commission.transaction_status,'')) not in ('CLOSED','PAID') then
   raise exception 'Trade % is not closed.',v_commission.transaction_number;
  end if;
  if exists(select 1 from public.dv_accounting_brokerage_payment_items i where i.commission_id=v_commission.commission_id) then
   raise exception 'Trade % has already been included in a brokerage payment.',v_commission.transaction_number;
  end if;
  if v_company_id is null then v_company_id:=v_commission.company_id; v_source_account_id:=v_commission.source_account_id;
  elsif v_company_id<>v_commission.company_id or v_source_account_id<>v_commission.source_account_id then
   raise exception 'All selected trades must use the same company and Commission Trust account.';
  end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=v_commission.source_account_id
   and b.company_id=v_commission.company_id and b.account_type='COMMISSION_TRUST' and b.active=true) then
   raise exception 'Commission Trust account is inactive or does not belong to this company.';
  end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=p_operating_account_id
   and b.company_id=v_commission.company_id and b.account_type='OPERATING' and b.active=true) then
   raise exception 'Operating account must belong to the same company as the selected trades.';
  end if;
  v_brokerage_amount:=round(coalesce(v_commission.brokerage_share,0),2);
  v_brokerage_hst:=round(coalesce(v_commission.brokerage_hst_amount,0),2);
  v_item_amount:=round(v_brokerage_amount+v_brokerage_hst,2);
  if v_item_amount<=0 then raise exception 'Trade % has no brokerage amount payable.',v_commission.transaction_number; end if;
  select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0)
   into v_available_liability from public.dv_accounting_trust_liabilities l
   where l.company_id=v_commission.company_id and l.trust_account_type='COMMISSION_TRUST'
    and coalesce(l.client_name,'')=coalesce(v_commission.client_name,'')
    and coalesce(l.matter,'')=coalesce(v_commission.matter,'');
  if coalesce(v_available_liability,0)+0.005<v_item_amount then
   raise exception 'Insufficient Commission Trust liability for trade %. Due: %, available: %.',
    v_commission.transaction_number,to_char(v_item_amount,'FM999999990.00'),to_char(coalesce(v_available_liability,0),'FM999999990.00');
  end if;
  v_trust_result:=public.dv_accounting_post_trust_transaction(
   v_commission.company_id,v_commission.source_account_id,v_commission.transaction_id,p_payment_date,
   'COMMISSION_TRUST','DISBURSEMENT',v_commission.client_name,v_commission.matter,
   'Brokerage bulk payment - '||v_commission.transaction_number,v_item_amount,
   'BROKERAGE-BULK:'||v_batch_id::text||':'||v_commission.commission_id::text);
  v_trust_id:=(v_trust_result->>'trust_transaction_id')::uuid;
  insert into public.dv_accounting_brokerage_payment_items(batch_id,company_id,commission_id,transaction_id,
   trust_transaction_id,brokerage_amount,brokerage_hst_amount,total_amount)
  values(v_batch_id,v_commission.company_id,v_commission.commission_id,v_commission.transaction_id,
   v_trust_id,v_brokerage_amount,v_brokerage_hst,v_item_amount);
  v_total:=v_total+v_item_amount; v_count:=v_count+1;
  v_items:=v_items||jsonb_build_array(jsonb_build_object('commission_id',v_commission.commission_id,
   'transaction_id',v_commission.transaction_id,'transaction_number',v_commission.transaction_number,
   'brokerage_amount',v_brokerage_amount,'brokerage_hst_amount',v_brokerage_hst,'total_amount',v_item_amount));
 end loop;
 if v_count<>cardinality(p_commission_ids) then raise exception 'One or more selected trades are not eligible.'; end if;
 select coalesce(ba.opening_balance,0)+coalesce(sum(bt.amount),0) into v_source_balance
 from public.dv_accounting_bank_accounts ba left join public.dv_accounting_bank_transactions bt on bt.bank_account_id=ba.id
 where ba.id=v_source_account_id group by ba.id,ba.opening_balance;
 if coalesce(v_source_balance,0)<-0.005 then raise exception 'Insufficient Commission Trust bank balance for this combined payment.'; end if;
 insert into public.dv_accounting_brokerage_payment_batches(id,company_id,source_bank_account_id,destination_bank_account_id,
  payment_date,payment_reference,total_amount,trade_count,created_by)
 values(v_batch_id,v_company_id,v_source_account_id,p_operating_account_id,p_payment_date,trim(p_payment_reference),
  round(v_total,2),v_count,auth.uid());
 insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
 values(p_operating_account_id,p_payment_date,'Brokerage bulk payment from Commission Trust ('||v_count||' trades)',
  round(v_total,2),false,'BROKERAGE-BULK:'||v_batch_id::text);
 return jsonb_build_object('ok',true,'batch_id',v_batch_id,'payment_reference',trim(p_payment_reference),
  'payment_date',p_payment_date,'trade_count',v_count,'total_amount',round(v_total,2),'items',v_items);
end; $$;
revoke all on function public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date) from public,anon;
grant execute on function public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date) to authenticated;


-- Corrected posting logic: use each trade's remaining trust ledger balance.
create or replace function public.dv_accounting_issue_brokerage_bulk_payment(
 p_commission_ids uuid[],p_operating_account_id uuid,p_payment_reference text,p_payment_date date
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_commission record; v_batch_id uuid:=gen_random_uuid(); v_company_id uuid; v_source_account_id uuid;
 v_available_liability numeric(14,2); v_source_balance numeric(14,2); v_total numeric(14,2):=0;
 v_item_amount numeric(14,2); v_brokerage_amount numeric(14,2); v_brokerage_hst numeric(14,2);
 v_trust_result jsonb; v_trust_id uuid; v_count integer:=0; v_items jsonb:='[]'::jsonb;
begin
 if auth.uid() is null or not public.dv_accounting_has_permission_all_scope('commission.issue')
  or not public.dv_accounting_has_permission_all_scope('banking.reconcile') then raise exception 'You do not have permission to issue a brokerage bulk payment.'; end if;
 if coalesce(array_length(p_commission_ids,1),0)<1 or array_length(p_commission_ids,1)>100 then raise exception 'Select between 1 and 100 eligible trades.'; end if;
 if nullif(trim(coalesce(p_payment_reference,'')),'') is null or p_payment_date is null then raise exception 'Payment reference and date are required.'; end if;
 if cardinality(p_commission_ids)<>(select count(distinct x) from unnest(p_commission_ids) x) then raise exception 'The selection contains duplicate trades.'; end if;
 if not exists(select 1 from public.dv_accounting_bank_accounts where id=p_operating_account_id and account_type='OPERATING' and active=true) then raise exception 'Select an active Operating bank account.'; end if;
 for v_commission in
  select c.id commission_id,c.transaction_id,c.status commission_status,t.company_id,t.transaction_number,t.status transaction_status,
   ch.brokerage_hst_amount,dep.bank_account_id source_account_id,dep.client_name,dep.matter
  from public.dv_accounting_commissions c join public.dv_accounting_transactions t on t.id=c.transaction_id
  join lateral(select x.brokerage_hst_amount from public.dv_accounting_commission_cheques x where x.commission_id=c.id and upper(coalesce(x.status,''))='ISSUED' order by x.issued_at desc nulls last,x.created_at desc limit 1) ch on true
  join lateral(select x.bank_account_id,x.client_name,x.matter from public.dv_accounting_trust_transactions x where x.transaction_id=t.id and x.trust_account_type='COMMISSION_TRUST' and x.direction='DEPOSIT' and x.status='POSTED' order by x.created_at desc limit 1) dep on true
  where c.id=any(p_commission_ids) order by t.transaction_number for update of c
 loop
  if upper(coalesce(v_commission.commission_status,''))<>'PAID' then raise exception 'Commission for trade % must be paid/issued to the agent first.',v_commission.transaction_number; end if;
  if upper(coalesce(v_commission.transaction_status,'')) not in ('CLOSED','PAID') then raise exception 'Trade % is not closed.',v_commission.transaction_number; end if;
  if exists(select 1 from public.dv_accounting_brokerage_payment_items i where i.commission_id=v_commission.commission_id) then raise exception 'Trade % has already been included in a brokerage payment.',v_commission.transaction_number; end if;
  if v_company_id is null then v_company_id:=v_commission.company_id; v_source_account_id:=v_commission.source_account_id;
  elsif v_company_id<>v_commission.company_id or v_source_account_id<>v_commission.source_account_id then raise exception 'All selected trades must use the same company and Commission Trust account.'; end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=v_commission.source_account_id and b.company_id=v_commission.company_id and b.account_type='COMMISSION_TRUST' and b.active=true) then raise exception 'Commission Trust account is inactive or does not belong to this company.'; end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=p_operating_account_id and b.company_id=v_commission.company_id and b.account_type='OPERATING' and b.active=true) then raise exception 'Operating account must belong to the same company as the selected trades.'; end if;
  select round(coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0),2) into v_item_amount
  from public.dv_accounting_trust_liabilities l where l.company_id=v_commission.company_id and l.transaction_id=v_commission.transaction_id and l.trust_account_type='COMMISSION_TRUST';
  if coalesce(v_item_amount,0)<=0.005 then raise exception 'Trade % has no remaining Commission Trust balance. It may already have been transferred to General Operating.',v_commission.transaction_number; end if;
  v_brokerage_hst:=round(coalesce(v_commission.brokerage_hst_amount,0),2);
  if v_brokerage_hst<0 or v_brokerage_hst>v_item_amount then raise exception 'The saved brokerage HST for trade % is greater than its remaining trust balance. Review the commission cheque before paying.',v_commission.transaction_number; end if;
  v_brokerage_amount:=round(v_item_amount-v_brokerage_hst,2);
  select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0) into v_available_liability
  from public.dv_accounting_trust_liabilities l where l.company_id=v_commission.company_id and l.trust_account_type='COMMISSION_TRUST'
   and coalesce(l.client_name,'')=coalesce(v_commission.client_name,'') and coalesce(l.matter,'')=coalesce(v_commission.matter,'');
  if coalesce(v_available_liability,0)+0.005<v_item_amount then raise exception 'Insufficient Commission Trust liability for trade %. Due: %, available: %.',v_commission.transaction_number,to_char(v_item_amount,'FM999999990.00'),to_char(coalesce(v_available_liability,0),'FM999999990.00'); end if;
  v_trust_result:=public.dv_accounting_post_trust_transaction(v_commission.company_id,v_commission.source_account_id,v_commission.transaction_id,p_payment_date,'COMMISSION_TRUST','DISBURSEMENT',v_commission.client_name,v_commission.matter,'Brokerage bulk payment - '||v_commission.transaction_number,v_item_amount,'BROKERAGE-BULK:'||v_batch_id::text||':'||v_commission.commission_id::text);
  v_trust_id:=(v_trust_result->>'trust_transaction_id')::uuid;
  insert into public.dv_accounting_brokerage_payment_items(batch_id,company_id,commission_id,transaction_id,trust_transaction_id,brokerage_amount,brokerage_hst_amount,total_amount)
  values(v_batch_id,v_commission.company_id,v_commission.commission_id,v_commission.transaction_id,v_trust_id,v_brokerage_amount,v_brokerage_hst,v_item_amount);
  v_total:=v_total+v_item_amount; v_count:=v_count+1;
  v_items:=v_items||jsonb_build_array(jsonb_build_object('commission_id',v_commission.commission_id,'transaction_id',v_commission.transaction_id,'transaction_number',v_commission.transaction_number,'brokerage_amount',v_brokerage_amount,'brokerage_hst_amount',v_brokerage_hst,'total_amount',v_item_amount));
 end loop;
 if v_count<>cardinality(p_commission_ids) then raise exception 'One or more selected trades are not eligible.'; end if;
 select coalesce(ba.opening_balance,0)+coalesce(sum(bt.amount),0) into v_source_balance from public.dv_accounting_bank_accounts ba left join public.dv_accounting_bank_transactions bt on bt.bank_account_id=ba.id where ba.id=v_source_account_id group by ba.id,ba.opening_balance;
 if coalesce(v_source_balance,0)<-0.005 then raise exception 'Insufficient Commission Trust bank balance for this combined payment.'; end if;
 insert into public.dv_accounting_brokerage_payment_batches(id,company_id,source_bank_account_id,destination_bank_account_id,payment_date,payment_reference,total_amount,trade_count,created_by)
 values(v_batch_id,v_company_id,v_source_account_id,p_operating_account_id,p_payment_date,trim(p_payment_reference),round(v_total,2),v_count,auth.uid());
 insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
 values(p_operating_account_id,p_payment_date,'Brokerage bulk payment from Commission Trust ('||v_count||' trades)',round(v_total,2),false,'BROKERAGE-BULK:'||v_batch_id::text);
 return jsonb_build_object('ok',true,'batch_id',v_batch_id,'payment_reference',trim(p_payment_reference),'payment_date',p_payment_date,'trade_count',v_count,'total_amount',round(v_total,2),'items',v_items);
end; $$;
revoke all on function public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date) from public,anon;
grant execute on function public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date) to authenticated;