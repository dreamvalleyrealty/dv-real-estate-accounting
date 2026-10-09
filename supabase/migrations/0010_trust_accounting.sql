-- Trust accounting and monthly reconciliation
create table if not exists public.dv_accounting_trust_transactions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 bank_account_id uuid references public.dv_accounting_bank_accounts(id),
 transaction_id uuid references public.dv_accounting_transactions(id),
 ledger_date date not null default current_date,
 trust_account_type text not null check (trust_account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
 direction text not null check (direction in ('DEPOSIT','DISBURSEMENT')),
 client_name text,
 matter text,
 description text not null,
 amount numeric(14,2) not null check (amount>0),
 reference text,
 status text not null default 'POSTED' check (status in ('POSTED','VOID')),
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_trust_liabilities(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 trust_transaction_id uuid references public.dv_accounting_trust_transactions(id) on delete cascade,
 transaction_id uuid references public.dv_accounting_transactions(id),
 trust_account_type text not null check (trust_account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
 client_name text,
 matter text,
 amount numeric(14,2) not null check (amount>0),
 direction text not null check (direction in ('RECEIVABLE','RELEASED')),
 created_at timestamptz not null default now()
);

alter table public.dv_accounting_reconciliations add column if not exists trust_liability_balance numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists bank_to_book_difference numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists bank_to_liability_difference numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists reviewed_by text;
alter table public.dv_accounting_reconciliations add column if not exists review_signed_at timestamptz;

alter table public.dv_accounting_trust_transactions enable row level security;
alter table public.dv_accounting_trust_liabilities enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_trust_transactions;
drop policy if exists "authenticated access" on public.dv_accounting_trust_liabilities;
create policy "authenticated access" on public.dv_accounting_trust_transactions for all to authenticated using(true) with check(true);
create policy "authenticated access" on public.dv_accounting_trust_liabilities for all to authenticated using(true) with check(true);

create or replace function public.dv_accounting_post_trust_transaction(
 p_company_id uuid,
 p_bank_account_id uuid,
 p_transaction_id uuid,
 p_ledger_date date,
 p_trust_account_type text,
 p_direction text,
 p_client_name text,
 p_matter text,
 p_description text,
 p_amount numeric,
 p_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare tt uuid; li uuid; company uuid; bank_type text;
begin
 if p_amount is null or p_amount<=0 then raise exception 'Trust amount must be greater than zero'; end if;
 if p_direction not in ('DEPOSIT','DISBURSEMENT') then raise exception 'Invalid trust direction'; end if;
 select account_type into bank_type from public.dv_accounting_bank_accounts where id=p_bank_account_id;
 if bank_type is null then raise exception 'Trust bank account not found'; end if;
 if bank_type<>p_trust_account_type then raise exception 'Bank account type does not match trust account type'; end if;
 company:=coalesce(p_company_id,(select company_id from public.dv_accounting_bank_accounts where id=p_bank_account_id));
 insert into public.dv_accounting_trust_transactions(company_id,bank_account_id,transaction_id,ledger_date,trust_account_type,direction,client_name,matter,description,amount,reference)
 values(company,p_bank_account_id,p_transaction_id,coalesce(p_ledger_date,current_date),p_trust_account_type,p_direction,p_client_name,p_matter,p_description,p_amount,p_reference)
 returning id into tt;
 insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
 values(company,tt,p_transaction_id,p_trust_account_type,p_client_name,p_matter,p_amount,case when p_direction='DEPOSIT' then 'RECEIVABLE' else 'RELEASED' end)
 returning id into li;
 return jsonb_build_object('ok',true,'trust_transaction_id',tt,'liability_id',li);
end $$;

revoke all on function public.dv_accounting_post_trust_transaction(uuid,uuid,uuid,date,text,text,text,text,text,numeric,text) from public;
grant execute on function public.dv_accounting_post_trust_transaction(uuid,uuid,uuid,date,text,text,text,text,text,numeric,text) to authenticated;
