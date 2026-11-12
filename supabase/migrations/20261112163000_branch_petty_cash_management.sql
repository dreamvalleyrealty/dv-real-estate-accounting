-- Branch-level petty cash management.
create table if not exists public.dv_accounting_petty_cash_funds (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.dv_accounting_companies(id),
 branch_id uuid not null references public.dv_accounting_branches(id), custodian_user_id uuid,
 float_amount numeric(14,2) not null default 0 check(float_amount>=0), active boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,branch_id)
);
create table if not exists public.dv_accounting_petty_cash_settings (
 company_id uuid primary key references public.dv_accounting_companies(id),
 approval_threshold numeric(14,2) not null default 100 check(approval_threshold>=0),
 receipt_threshold numeric(14,2) not null default 25 check(receipt_threshold>=0), updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.dv_accounting_petty_cash_transactions (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.dv_accounting_companies(id),
 fund_id uuid not null references public.dv_accounting_petty_cash_funds(id),
 transaction_type text not null check(transaction_type in ('FUNDING','EXPENSE')), transaction_date date not null default current_date,
 amount numeric(14,2) not null check(amount>0), source text, bank_account_id uuid references public.dv_accounting_bank_accounts(id),
 shareholder_name text, vendor text, category text, description text, hst_amount numeric(14,2) not null default 0 check(hst_amount>=0),
 receipt_storage_path text, receipt_file_name text, reference text,
 approval_status text not null default 'APPROVED' check(approval_status in ('PENDING','APPROVED','REJECTED')),
 approval_note text, approved_by uuid, approved_at timestamptz, created_by uuid not null,
 linked_expense_id uuid references public.dv_accounting_expenses(id), journal_entry_id uuid references public.dv_accounting_journal_entries(id), created_at timestamptz not null default now()
);
create index if not exists dv_petty_cash_transactions_fund_date_idx on public.dv_accounting_petty_cash_transactions(fund_id,transaction_date desc,created_at desc);
create index if not exists dv_petty_cash_transactions_company_status_idx on public.dv_accounting_petty_cash_transactions(company_id,approval_status,transaction_type);
alter table public.dv_accounting_petty_cash_funds enable row level security;
alter table public.dv_accounting_petty_cash_settings enable row level security;
alter table public.dv_accounting_petty_cash_transactions enable row level security;
create policy petty_cash_fund_read on public.dv_accounting_petty_cash_funds for select to authenticated using (
 company_id=(select up.company_id from public.dv_accounting_user_profiles up where up.user_id=auth.uid() and up.active=true)
 and (public.dv_accounting_current_user_role()='SUPERADMIN' or (coalesce((public.dv_accounting_get_my_permissions()->'petty_cash.view'->>'allowed')::boolean,false)
 and (coalesce(public.dv_accounting_get_my_permissions()->'petty_cash.view'->>'scope',public.dv_accounting_get_my_permissions()->'petty_cash.view'->>'access_scope','BRANCH')='ALL' or custodian_user_id=auth.uid())))
);
create policy petty_cash_transaction_read on public.dv_accounting_petty_cash_transactions for select to authenticated using (
 company_id=(select up.company_id from public.dv_accounting_user_profiles up where up.user_id=auth.uid() and up.active=true)
 and exists(select 1 from public.dv_accounting_petty_cash_funds f where f.id=fund_id)
);
create policy petty_cash_settings_read on public.dv_accounting_petty_cash_settings for select to authenticated using (
 company_id=(select up.company_id from public.dv_accounting_user_profiles up where up.user_id=auth.uid() and up.active=true)
 and (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.manage'))
);
grant select on public.dv_accounting_petty_cash_funds,public.dv_accounting_petty_cash_settings,public.dv_accounting_petty_cash_transactions to authenticated;
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order) values
 ('petty_cash.view','Petty Cash','View petty cash','View assigned branch fund and cash transactions.',10),
 ('petty_cash.enter','Petty Cash','Record petty cash expenses','Submit branch petty cash expenses and receipts.',20),
 ('petty_cash.approve','Petty Cash','Approve petty cash expenses','Approve or reject petty cash expenses above the approval threshold.',30),
 ('petty_cash.fund','Petty Cash','Fund petty cash','Record approved funding from General Operating or shareholder loans.',40),
 ('petty_cash.manage','Petty Cash','Manage petty cash funds','Create branch funds, assign custodians and set branch float targets and policy thresholds.',50)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;
insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
select r.role,p.code,case when r.role='SUPERADMIN' then true when r.role='ADMIN' then true when r.role='MANAGER' and p.code in ('petty_cash.view','petty_cash.approve') then true when r.role='ACCOUNTANT' and p.code='petty_cash.view' then true when r.role='STAFF' and p.code in ('petty_cash.view','petty_cash.enter') then true else false end,
case when r.role='STAFF' and p.code in ('petty_cash.view','petty_cash.enter') then 'BRANCH' else 'ALL' end
from (select distinct role from public.dv_accounting_role_permission_rules) r cross join (values('petty_cash.view'),('petty_cash.enter'),('petty_cash.approve'),('petty_cash.fund'),('petty_cash.manage')) p(code)
on conflict(role,permission_code) do update set allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now();

create or replace function public.dv_accounting_petty_cash_save_fund(p_branch_id uuid,p_float_amount numeric,p_custodian_user_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_fund public.dv_accounting_petty_cash_funds%rowtype;
begin
 if auth.uid() is null or not (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.manage')) then raise exception 'You do not have permission to manage petty cash funds'; end if;
 select company_id into v_company from public.dv_accounting_user_profiles where user_id=auth.uid() and active=true;
 if v_company is null then raise exception 'Active accounting company profile is required'; end if;
 if p_float_amount is null or p_float_amount<0 then raise exception 'Enter a valid branch float amount'; end if;
 if not exists(select 1 from public.dv_accounting_branches where id=p_branch_id and company_id=v_company and active=true) then raise exception 'Active branch not found for this company'; end if;
 if p_custodian_user_id is not null and not exists(select 1 from public.dv_accounting_user_profiles where user_id=p_custodian_user_id and company_id=v_company and active=true) then raise exception 'Select an active accounting user in this company as custodian'; end if;
 insert into public.dv_accounting_petty_cash_funds(company_id,branch_id,float_amount,custodian_user_id) values(v_company,p_branch_id,round(p_float_amount,2),p_custodian_user_id)
 on conflict(company_id,branch_id) do update set float_amount=excluded.float_amount,custodian_user_id=excluded.custodian_user_id,updated_at=now() returning * into v_fund;
 return to_jsonb(v_fund);
end $$;
create or replace function public.dv_accounting_petty_cash_save_settings(p_approval_threshold numeric,p_receipt_threshold numeric)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_row public.dv_accounting_petty_cash_settings%rowtype;
begin
 if auth.uid() is null or not (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.manage')) then raise exception 'You do not have permission to change petty cash settings'; end if;
 select company_id into v_company from public.dv_accounting_user_profiles where user_id=auth.uid() and active=true;
 if v_company is null then raise exception 'Active accounting company profile is required'; end if;
 if p_approval_threshold<0 or p_receipt_threshold<0 then raise exception 'Thresholds cannot be negative'; end if;
 insert into public.dv_accounting_petty_cash_settings(company_id,approval_threshold,receipt_threshold,updated_by) values(v_company,round(p_approval_threshold,2),round(p_receipt_threshold,2),auth.uid())
 on conflict(company_id) do update set approval_threshold=excluded.approval_threshold,receipt_threshold=excluded.receipt_threshold,updated_at=now(),updated_by=auth.uid() returning * into v_row;
 return to_jsonb(v_row);
end $$;
create or replace function public.dv_accounting_petty_cash_post_expense(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.dv_accounting_petty_cash_transactions%rowtype; f public.dv_accounting_petty_cash_funds%rowtype; b public.dv_accounting_branches%rowtype; e_id uuid; je uuid; exp_gl uuid; itc_gl uuid; cash_gl uuid; cash_code text; exp_code text; v_total numeric(14,2);
begin
 select * into t from public.dv_accounting_petty_cash_transactions where id=p_transaction_id for update;
 if not found or t.transaction_type<>'EXPENSE' then raise exception 'Petty cash expense not found'; end if;
 if t.linked_expense_id is not null then return jsonb_build_object('status','ALREADY_POSTED','expense_id',t.linked_expense_id,'journal_entry_id',t.journal_entry_id); end if;
 select * into f from public.dv_accounting_petty_cash_funds where id=t.fund_id; select * into b from public.dv_accounting_branches where id=f.branch_id;
 v_total:=round(t.amount+t.hst_amount,2); exp_code:='6'||lpad((abs(hashtext(coalesce(nullif(trim(t.category),''),'General Expense')))%999)::text,3,'0');
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
create or replace function public.dv_accounting_petty_cash_record_funding(p_fund_id uuid,p_amount numeric,p_source text,p_bank_account_id uuid default null,p_shareholder_name text default null,p_transaction_date date default current_date,p_reference text default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f public.dv_accounting_petty_cash_funds%rowtype; b public.dv_accounting_bank_accounts%rowtype; br public.dv_accounting_branches%rowtype; v_company uuid; cash_gl uuid; credit_gl uuid; je uuid; tx uuid; cash_code text; source_code text;
begin
 if auth.uid() is null or not (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.fund')) then raise exception 'You do not have permission to fund petty cash'; end if;
 select * into f from public.dv_accounting_petty_cash_funds where id=p_fund_id for update; if not found or not f.active then raise exception 'Active petty cash fund not found'; end if;
 select company_id into v_company from public.dv_accounting_user_profiles where user_id=auth.uid() and active=true; if v_company is distinct from f.company_id then raise exception 'Fund belongs to a different accounting company'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Funding amount must be greater than zero'; end if;
 select * into br from public.dv_accounting_branches where id=f.branch_id; cash_code:='PC-'||upper(regexp_replace(coalesce(br.branch_code,'BR'),'[^A-Z0-9]','','g'));
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(f.company_id,cash_code,'Petty Cash - '||br.name,'ASSET') on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do nothing;
 select id into cash_gl from public.dv_accounting_gl_accounts where company_id=f.company_id and code=cash_code;
 if upper(p_source)='GENERAL_OPERATING' then
  select * into b from public.dv_accounting_bank_accounts where id=p_bank_account_id and active=true for update;
  if not found or b.company_id is distinct from f.company_id or b.account_type<>'OPERATING' then raise exception 'Select an active General Operating bank account for this company'; end if;
  source_code:='1000'; insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(f.company_id,source_code,'Operating Bank','ASSET') on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do nothing;
 elsif upper(p_source)='SHAREHOLDER_LOAN' then
  if nullif(trim(p_shareholder_name),'') is null then raise exception 'Enter the shareholder name for this loan'; end if;
  source_code:='LIB-SHAREHOLDER-ST'; insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(f.company_id,source_code,'Shareholder / Director Loan - Current','LIABILITY') on conflict on constraint dv_accounting_gl_accounts_company_id_code_key do nothing;
 else raise exception 'Choose General Operating or Shareholder Loan as the funding source'; end if;
 select id into credit_gl from public.dv_accounting_gl_accounts where company_id=f.company_id and code=source_code;
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo) values(f.company_id,coalesce(p_transaction_date,current_date),'PETTY_CASH_FUNDING',f.id,'Petty cash funding - '||br.name||' - '||upper(p_source)) returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,cash_gl,round(p_amount,2),0);
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,credit_gl,0,round(p_amount,2));
 insert into public.dv_accounting_petty_cash_transactions(company_id,fund_id,transaction_type,transaction_date,amount,source,bank_account_id,shareholder_name,reference,description,approval_status,approved_by,approved_at,created_by,journal_entry_id)
 values(f.company_id,f.id,'FUNDING',coalesce(p_transaction_date,current_date),round(p_amount,2),upper(p_source),case when upper(p_source)='GENERAL_OPERATING' then p_bank_account_id else null end,case when upper(p_source)='SHAREHOLDER_LOAN' then trim(p_shareholder_name) else null end,nullif(trim(p_reference),''),nullif(trim(p_notes),''),'APPROVED',auth.uid(),now(),auth.uid(),je) returning id into tx;
 return jsonb_build_object('transaction_id',tx,'journal_entry_id',je,'amount',round(p_amount,2),'status','FUNDED');
end $$;
create or replace function public.dv_accounting_petty_cash_submit_expense(p_fund_id uuid,p_transaction_date date,p_vendor text,p_category text,p_description text,p_amount numeric,p_hst_amount numeric,p_receipt_storage_path text default null,p_receipt_file_name text default null,p_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f public.dv_accounting_petty_cash_funds%rowtype; v_company uuid; v_perm jsonb; v_approval numeric(14,2):=100; v_receipt numeric(14,2):=25; v_total numeric(14,2); v_status text; tx uuid; result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into f from public.dv_accounting_petty_cash_funds where id=p_fund_id and active=true; if not found then raise exception 'Active petty cash fund not found'; end if;
 select company_id into v_company from public.dv_accounting_user_profiles where user_id=auth.uid() and active=true; if v_company is distinct from f.company_id then raise exception 'Fund belongs to a different company'; end if;
 v_perm:=public.dv_accounting_get_my_permissions()->'petty_cash.enter';
 if not (f.custodian_user_id=auth.uid() and coalesce((v_perm->>'allowed')::boolean,false)) and not public.dv_accounting_has_permission_all_scope('petty_cash.enter') then raise exception 'You are not assigned to this branch petty cash fund'; end if;
 select coalesce(approval_threshold,100),coalesce(receipt_threshold,25) into v_approval,v_receipt from public.dv_accounting_petty_cash_settings where company_id=f.company_id;
 v_approval:=coalesce(v_approval,100); v_receipt:=coalesce(v_receipt,25); v_total:=round(coalesce(p_amount,0)+coalesce(p_hst_amount,0),2);
 if nullif(trim(coalesce(p_vendor,'')),'') is null or nullif(trim(coalesce(p_category,'')),'') is null or nullif(trim(coalesce(p_description,'')),'') is null then raise exception 'Vendor, category and description are required'; end if;
 if coalesce(p_amount,0)<=0 or coalesce(p_hst_amount,0)<0 then raise exception 'Enter valid expense and HST amounts'; end if;
 if v_total>v_receipt and nullif(trim(coalesce(p_receipt_storage_path,'')),'') is null then raise exception 'A receipt is required for expenses above $%',v_receipt; end if;
 v_status:=case when v_total>v_approval then 'PENDING' else 'APPROVED' end;
 insert into public.dv_accounting_petty_cash_transactions(company_id,fund_id,transaction_type,transaction_date,amount,hst_amount,vendor,category,description,receipt_storage_path,receipt_file_name,reference,approval_status,approved_by,approved_at,created_by)
 values(f.company_id,f.id,'EXPENSE',coalesce(p_transaction_date,current_date),round(p_amount,2),round(p_hst_amount,2),trim(p_vendor),trim(p_category),trim(p_description),nullif(trim(p_receipt_storage_path),''),nullif(trim(p_receipt_file_name),''),nullif(trim(p_reference),''),v_status,case when v_status='APPROVED' then auth.uid() else null end,case when v_status='APPROVED' then now() else null end,auth.uid()) returning id into tx;
 if v_status='APPROVED' then result:=public.dv_accounting_petty_cash_post_expense(tx); return result||jsonb_build_object('transaction_id',tx,'approval_status','APPROVED'); end if;
 return jsonb_build_object('transaction_id',tx,'approval_status','PENDING','total_amount',v_total);
end $$;
create or replace function public.dv_accounting_petty_cash_review_expense(p_transaction_id uuid,p_approve boolean,p_note text default null,p_cash_returned boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.dv_accounting_petty_cash_transactions%rowtype; result jsonb;
begin
 if auth.uid() is null or not (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.approve')) then raise exception 'You do not have permission to review petty cash expenses'; end if;
 select * into t from public.dv_accounting_petty_cash_transactions where id=p_transaction_id for update;
 if not found or t.transaction_type<>'EXPENSE' or t.approval_status<>'PENDING' then raise exception 'Pending petty cash expense not found'; end if;
 if p_approve then update public.dv_accounting_petty_cash_transactions set approval_note=nullif(trim(p_note),''),approved_by=auth.uid(),approved_at=now() where id=t.id; result:=public.dv_accounting_petty_cash_post_expense(t.id); return result||jsonb_build_object('approval_status','APPROVED'); end if;
 if not p_cash_returned then raise exception 'Confirm that the cash has been returned to the petty cash custodian before rejecting this expense'; end if;
 if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'A rejection reason is required'; end if;
 update public.dv_accounting_petty_cash_transactions set approval_status='REJECTED',approval_note=trim(p_note),approved_by=auth.uid(),approved_at=now() where id=t.id;
 return jsonb_build_object('transaction_id',t.id,'approval_status','REJECTED','cash_returned',true);
end $$;
grant execute on function public.dv_accounting_petty_cash_save_fund(uuid,numeric,uuid) to authenticated;
grant execute on function public.dv_accounting_petty_cash_save_settings(numeric,numeric) to authenticated;
grant execute on function public.dv_accounting_petty_cash_record_funding(uuid,numeric,text,uuid,text,date,text,text) to authenticated;
grant execute on function public.dv_accounting_petty_cash_submit_expense(uuid,date,text,text,text,numeric,numeric,text,text,text) to authenticated;
grant execute on function public.dv_accounting_petty_cash_review_expense(uuid,boolean,text,boolean) to authenticated;
