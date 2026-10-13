-- 0035: Map the expanded chart of accounts to the ledger and protect closed periods.
create table if not exists public.dv_accounting_periods (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
 period_name text not null,
 period_start date not null,
 period_end date not null,
 is_closed boolean not null default false,
 closed_at timestamptz,
 closed_by uuid,
 notes text,
 created_at timestamptz not null default now(),
 constraint dv_accounting_periods_date_order check(period_end>=period_start),
 constraint dv_accounting_periods_company_name_unique unique(company_id,period_name)
);
create index if not exists dv_accounting_periods_company_dates_idx on public.dv_accounting_periods(company_id,period_start,period_end);
alter table public.dv_accounting_periods enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_periods;
create policy "authenticated access" on public.dv_accounting_periods for all to authenticated using(true) with check(true);
insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type,active)
select c.company_id,c.code,c.name,
 case c.category_type when 'INCOME' then 'REVENUE' when 'EXPENSE' then 'EXPENSE' when 'ASSET' then 'ASSET' when 'TRUST_ASSET' then 'ASSET' when 'CURRENT_LIABILITY' then 'LIABILITY' when 'LONG_TERM_LIABILITY' then 'LIABILITY' when 'TRUST_LIABILITY' then 'LIABILITY' when 'EQUITY' then 'EQUITY' end,
 coalesce(c.active,true)
from public.dv_accounting_categories c where c.code is not null and trim(c.code)<>''
on conflict(company_id,code) do nothing;
create or replace view public.dv_accounting_v_balance_sheet as
select gl.company_id,gl.account_code,gl.account_name,gl.account_type,
 sum(case when gl.account_type in ('LIABILITY','EQUITY') then gl.credit-gl.debit else gl.debit-gl.credit end) as balance
from public.dv_accounting_v_general_ledger gl where gl.account_type in ('ASSET','LIABILITY','EQUITY')
group by gl.company_id,gl.account_code,gl.account_name,gl.account_type
union all
select gl.company_id,'3900'::text,'Current Year Earnings'::text,'EQUITY'::text,
 sum(case when gl.account_type='REVENUE' then gl.credit-gl.debit else gl.debit-gl.credit end) as balance
from public.dv_accounting_v_general_ledger gl where gl.account_type in ('REVENUE','EXPENSE')
group by gl.company_id;
create or replace function public.dv_accounting_prevent_closed_period_journal()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_date date;
begin
 if tg_table_name='dv_accounting_journal_entries' then
  v_company:=case when tg_op='DELETE' then old.company_id else new.company_id end;
  v_date:=case when tg_op='DELETE' then old.entry_date else new.entry_date end;
 else
  select je.company_id,je.entry_date into v_company,v_date from public.dv_accounting_journal_entries je
  where je.id=case when tg_op='DELETE' then old.journal_entry_id else new.journal_entry_id end;
  if not found then if tg_op='DELETE' then return old; else return new; end if; end if;
 end if;
 if exists(select 1 from public.dv_accounting_periods p where p.company_id=v_company and p.is_closed and v_date between p.period_start and p.period_end) then
  raise exception 'Accounting period is closed for date %. Reopen the period with authorized approval before changing journal entries.',v_date;
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end; $$;
drop trigger if exists dv_accounting_journal_entries_closed_period on public.dv_accounting_journal_entries;
create trigger dv_accounting_journal_entries_closed_period before insert or update or delete on public.dv_accounting_journal_entries for each row execute function public.dv_accounting_prevent_closed_period_journal();
drop trigger if exists dv_accounting_journal_lines_closed_period on public.dv_accounting_journal_lines;
create trigger dv_accounting_journal_lines_closed_period before insert or update or delete on public.dv_accounting_journal_lines for each row execute function public.dv_accounting_prevent_closed_period_journal();
