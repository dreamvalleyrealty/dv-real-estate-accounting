-- Correct petty cash posting for generated dv_accounting_expenses.total_amount.
create or replace function public.dv_accounting_petty_cash_post_expense(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.dv_accounting_petty_cash_transactions%rowtype; f public.dv_accounting_petty_cash_funds%rowtype; b public.dv_accounting_branches%rowtype; e_id uuid; je uuid; exp_gl uuid; itc_gl uuid; cash_gl uuid; cash_code text; exp_code text; v_total numeric(14,2);
begin
 select * into t from public.dv_accounting_petty_cash_transactions where id=p_transaction_id for update;
 if not found or t.transaction_type<>'EXPENSE' then raise exception 'Petty cash expense not found'; end if;
 if t.linked_expense_id is not null then return jsonb_build_object('status','ALREADY_POSTED','expense_id',t.linked_expense_id,'journal_entry_id',t.journal_entry_id); end if;
 select * into f from public.dv_accounting_petty_cash_funds where id=t.fund_id;
 select * into b from public.dv_accounting_branches where id=f.branch_id;
 v_total:=round(t.amount+t.hst_amount,2);
 exp_code:='6'||lpad((abs(hashtext(coalesce(nullif(trim(t.category),''),'General Expense')))%999)::text,3,'0');
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(t.company_id,exp_code,coalesce(nullif(trim(t.category),''),'General Expense'),'EXPENSE')
 on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do update set name=excluded.name returning id into exp_gl;
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(t.company_id,'1300','HST Input Tax Credits','ASSET') on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do nothing;
 select id into itc_gl from public.dv_accounting_gl_accounts where company_id=t.company_id and code='1300';
 cash_code:='PC-'||upper(regexp_replace(coalesce(b.branch_code,'BR'),'[^A-Z0-9]','','g'));
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(t.company_id,cash_code,'Petty Cash - '||b.name,'ASSET') on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do nothing;
 select id into cash_gl from public.dv_accounting_gl_accounts where company_id=t.company_id and code=cash_code;
 insert into public.dv_accounting_expenses(company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status,created_by,approval_status,hst_rate,branch_id,invoice_storage_path,invoice_file_name,invoice_uploaded_at,approved_at,approved_by,posted_at,paid_at)
 values(t.company_id,t.transaction_date,t.vendor,t.category,t.description,t.amount,t.hst_amount,'POSTED','PAID',t.created_by,'APPROVED',case when t.amount>0 then round(t.hst_amount/t.amount*100,2) else 0 end,f.branch_id,t.receipt_storage_path,t.receipt_file_name,case when t.receipt_storage_path is not null then now() else null end,now(),auth.uid(),now(),now()) returning id into e_id;
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo) values(t.company_id,t.transaction_date,'PETTY_CASH_EXPENSE',t.id,coalesce(t.description,t.vendor,'Petty cash expense')) returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,exp_gl,t.amount,0);
 if t.hst_amount>0 then insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,itc_gl,t.hst_amount,0); end if;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,cash_gl,0,v_total);
 update public.dv_accounting_expenses set journal_entry_id=je where id=e_id;
 insert into public.dv_accounting_expense_payments(company_id,expense_id,payment_date,amount,bank_account_id,reference,journal_entry_id,paid_by,payment_source,payee_type,payee_name,payment_method)
 values(t.company_id,e_id,t.transaction_date,v_total,null,t.reference,je,t.created_by,'PETTY_CASH','VENDOR',t.vendor,'CASH');
 update public.dv_accounting_petty_cash_transactions set linked_expense_id=e_id,journal_entry_id=je,approval_status='APPROVED',approved_by=coalesce(approved_by,auth.uid()),approved_at=coalesce(approved_at,now()) where id=t.id;
 return jsonb_build_object('status','POSTED','expense_id',e_id,'journal_entry_id',je,'total_amount',v_total);
end $$;
revoke all on function public.dv_accounting_petty_cash_post_expense(uuid) from public,anon,authenticated;
