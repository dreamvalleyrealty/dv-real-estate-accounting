-- Pay multiple approved invoices for one vendor with one bank payment.
create or replace function public.dv_accounting_pay_vendor_invoices_batch(
  p_expense_ids uuid[],
  p_bank_account_id uuid,
  p_payment_date date default current_date,
  p_reference text default null,
  p_payment_method text default 'CHEQUE',
  p_cheque_number text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.dv_accounting_expenses%rowtype;
  b public.dv_accounting_bank_accounts%rowtype;
  v_vendor text;
  v_company uuid;
  v_count integer;
  v_total numeric(14,2) := 0;
  v_paid numeric(14,2);
  v_due numeric(14,2);
  v_ap uuid;
  v_bank_gl uuid;
  v_je uuid;
  v_payment_id uuid;
  v_method text := upper(trim(coalesce(p_payment_method,'CHEQUE')));
  v_ref text := nullif(trim(p_reference),'');
  v_cheque text := nullif(trim(p_cheque_number),'');
  v_ids uuid[];
begin
  if coalesce(cardinality(p_expense_ids),0)<2 then
    raise exception 'Select at least two invoices for a batch payment';
  end if;
  select array_agg(distinct x order by x) into v_ids from unnest(p_expense_ids) x;
  if cardinality(v_ids)<>cardinality(p_expense_ids) then
    raise exception 'The selected invoice list contains duplicates';
  end if;
  if v_method not in ('CHEQUE','EFT') then raise exception 'Payment method must be Cheque or EFT'; end if;
  if v_method='CHEQUE' and v_cheque is null then raise exception 'Enter a cheque number'; end if;
  if v_method='EFT' and v_ref is null then raise exception 'Enter the EFT confirmation reference'; end if;

  select * into b from public.dv_accounting_bank_accounts
   where id=p_bank_account_id and active=true for update;
  if not found then raise exception 'Operating bank account not found'; end if;
  if b.account_type<>'OPERATING' then raise exception 'Vendor payments must use an Operating account'; end if;

  select count(*), min(company_id), min(vendor)
    into v_count, v_company, v_vendor
  from public.dv_accounting_expenses where id=any(v_ids);
  if v_count<>cardinality(v_ids) then raise exception 'One or more selected invoices could not be found'; end if;
  if v_company is distinct from b.company_id then raise exception 'Bank account does not belong to the invoice company'; end if;
  if exists (
    select 1 from public.dv_accounting_expenses
    where id=any(v_ids) and (lower(trim(coalesce(vendor,'')))<>lower(trim(coalesce(v_vendor,''))) or company_id is distinct from v_company)
  ) then raise exception 'All selected invoices must belong to the same vendor and company'; end if;

  select id into v_ap from public.dv_accounting_gl_accounts where company_id=v_company and code='2000';
  if v_ap is null then raise exception 'Accounts Payable account is missing'; end if;
  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
  values(v_company,'1000','Operating Bank','ASSET')
  on conflict(company_id,code) do nothing;
  select id into v_bank_gl from public.dv_accounting_gl_accounts where company_id=v_company and code='1000';

  -- Lock invoices in a stable order and calculate each outstanding balance.
  for e in select * from public.dv_accounting_expenses where id=any(v_ids) order by id for update loop
    if e.posted_at is null then raise exception 'Invoice % must be posted before payment',coalesce(e.invoice_number,e.id::text); end if;
    if e.approval_status<>'APPROVED' then raise exception 'Invoice % must be approved before payment',coalesce(e.invoice_number,e.id::text); end if;
    if e.voided_at is not null then raise exception 'Voided invoices cannot be paid'; end if;
    select coalesce(sum(amount),0) into v_paid from public.dv_accounting_expense_payments where expense_id=e.id;
    if v_paid=0 and e.payment_status='PAID' then v_paid:=round(coalesce(e.amount,0)+coalesce(e.hst_amount,0),2); end if;
    v_due:=round(coalesce(e.amount,0)+coalesce(e.hst_amount,0)-v_paid,2);
    if v_due<=0 then raise exception 'Invoice % has no outstanding balance',coalesce(e.invoice_number,e.id::text); end if;
    v_total:=v_total+v_due;
  end loop;

  insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
  values(v_company,coalesce(p_payment_date,current_date),'EXPENSE_PAYMENT',v_ids[1],
    'Batch vendor payment - '||coalesce(v_vendor,'Vendor')||' ('||cardinality(v_ids)||' invoices)'||
    case when v_ref is not null then ' - '||v_ref when v_cheque is not null then ' - Cheque '||v_cheque else '' end)
  returning id into v_je;

  for e in select * from public.dv_accounting_expenses where id=any(v_ids) order by id loop
    select coalesce(sum(amount),0) into v_paid from public.dv_accounting_expense_payments where expense_id=e.id;
    if v_paid=0 and e.payment_status='PAID' then v_paid:=round(coalesce(e.amount,0)+coalesce(e.hst_amount,0),2); end if;
    v_due:=round(coalesce(e.amount,0)+coalesce(e.hst_amount,0)-v_paid,2);
    insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    values(v_je,v_ap,v_due,0);
    insert into public.dv_accounting_expense_payments(
      company_id,expense_id,payment_date,amount,bank_account_id,reference,journal_entry_id,
      paid_by,payment_source,payee_type,payee_name,payment_method,cheque_number
    ) values (
      v_company,e.id,coalesce(p_payment_date,current_date),v_due,p_bank_account_id,
      coalesce(v_ref,v_cheque),v_je,auth.uid(),'BANK','VENDOR',coalesce(v_vendor,'Vendor'),
      v_method,case when v_method='CHEQUE' then v_cheque else null end
    ) returning id into v_payment_id;
    update public.dv_accounting_expenses
      set payment_status='PAID',paid_at=now(),bank_account_id=p_bank_account_id
    where id=e.id;
  end loop;

  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(v_je,v_bank_gl,0,v_total);
  insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
  values(p_bank_account_id,coalesce(p_payment_date,current_date),
    'Vendor batch payment: '||coalesce(v_vendor,'Vendor')||' ('||cardinality(v_ids)||' invoices) ['||v_je::text||']',
    -v_total,false,coalesce(v_ref,v_cheque));

  return jsonb_build_object('status','PAID','vendor',v_vendor,'invoice_count',cardinality(v_ids),
    'total_amount',round(v_total,2),'journal_entry_id',v_je,'payment_method',v_method,
    'reference',coalesce(v_ref,v_cheque));
end;
$$;
grant execute on function public.dv_accounting_pay_vendor_invoices_batch(uuid[],uuid,date,text,text,text) to authenticated;
