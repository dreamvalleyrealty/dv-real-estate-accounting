-- Agent invoice register: isolated from transaction/vendor payables.
create table if not exists public.dv_agent_invoices (
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete restrict,
 invoice_number text not null unique,
 invoice_date date not null default current_date,
 due_date date,
 description text not null,
 subtotal numeric(14,2) not null check (subtotal >= 0),
 tax_rate numeric(7,4) not null default 13 check (tax_rate >= 0),
 tax_amount numeric(14,2) not null default 0 check (tax_amount >= 0),
 total_amount numeric(14,2) not null check (total_amount >= 0),
 paid_amount numeric(14,2) not null default 0 check (paid_amount >= 0),
 balance_amount numeric(14,2) not null check (balance_amount >= 0),
 status text not null default 'Open' check (status in ('Open','Partially Paid','Paid','Overdue','Void')),
 notes text,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.dv_agent_invoice_daily_sequences (
 invoice_day date primary key,
 last_number integer not null default 0 check (last_number between 0 and 99)
);
create or replace function public.dv_agent_invoice_number(p_day date default current_date)
returns text language plpgsql security definer set search_path=public as $$
declare v_next integer;
begin
 insert into public.dv_agent_invoice_daily_sequences(invoice_day,last_number) values(p_day,1)
 on conflict(invoice_day) do update set last_number=public.dv_agent_invoice_daily_sequences.last_number+1
 where public.dv_agent_invoice_daily_sequences.last_number<99
 returning last_number into v_next;
 if v_next is null then raise exception 'Daily invoice number limit reached'; end if;
 return to_char(p_day,'YYYYMMDD')||lpad(v_next::text,2,'0');
end; $$;
create or replace function public.dv_agent_invoice_before_insert()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.invoice_number is null or btrim(new.invoice_number)='' then
  new.invoice_number:=public.dv_agent_invoice_number(coalesce(new.invoice_date,current_date));
 end if;
 new.updated_at:=now();
 return new;
end; $$;
drop trigger if exists trg_dv_agent_invoice_before_insert on public.dv_agent_invoices;
create trigger trg_dv_agent_invoice_before_insert before insert on public.dv_agent_invoices
for each row execute function public.dv_agent_invoice_before_insert();

create table if not exists public.dv_agent_invoice_payments (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.dv_agent_invoices(id) on delete restrict,
 agent_id uuid not null references public.dv_accounting_agents(id) on delete restrict,
 amount numeric(14,2) not null check (amount>0),
 payment_date date not null default current_date,
 payment_method text not null,
 reference_number text,
 notes text,
 recorded_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create index if not exists idx_dv_agent_invoices_agent_date on public.dv_agent_invoices(agent_id,invoice_date desc);
create index if not exists idx_dv_agent_invoice_payments_invoice on public.dv_agent_invoice_payments(invoice_id,payment_date desc);

create or replace function public.dv_agent_invoice_refresh_balance()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_invoice_id uuid; v_total numeric(14,2); v_paid numeric(14,2); v_due date;
begin
 v_invoice_id:=coalesce(new.invoice_id,old.invoice_id);
 select total_amount,due_date into v_total,v_due from public.dv_agent_invoices where id=v_invoice_id for update;
 if not found then if tg_op='DELETE' then return old; else return new; end if; end if;
 select coalesce(sum(amount),0) into v_paid from public.dv_agent_invoice_payments where invoice_id=v_invoice_id;
 update public.dv_agent_invoices set paid_amount=v_paid,balance_amount=greatest(v_total-v_paid,0),
 status=case when v_paid>=v_total then 'Paid' when v_paid>0 then 'Partially Paid' when due_date is not null and due_date<current_date then 'Overdue' else 'Open' end,
 updated_at=now() where id=v_invoice_id;
 if tg_op='DELETE' then return old; else return new; end if;
end; $$;
drop trigger if exists trg_dv_agent_invoice_payment_balance on public.dv_agent_invoice_payments;
create trigger trg_dv_agent_invoice_payment_balance after insert or update or delete on public.dv_agent_invoice_payments
for each row execute function public.dv_agent_invoice_refresh_balance();

alter table public.dv_agent_invoices enable row level security;
alter table public.dv_agent_invoice_payments enable row level security;
drop policy if exists dv_agent_invoices_management_all on public.dv_agent_invoices;
create policy dv_agent_invoices_management_all on public.dv_agent_invoices for all to authenticated
using (public.dv_is_management_user()) with check (public.dv_is_management_user());
drop policy if exists dv_agent_invoices_agent_select on public.dv_agent_invoices;
create policy dv_agent_invoices_agent_select on public.dv_agent_invoices for select to authenticated
using (exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists dv_agent_invoice_payments_management_all on public.dv_agent_invoice_payments;
create policy dv_agent_invoice_payments_management_all on public.dv_agent_invoice_payments for all to authenticated
using (public.dv_is_management_user()) with check (public.dv_is_management_user());
drop policy if exists dv_agent_invoice_payments_agent_select on public.dv_agent_invoice_payments;
create policy dv_agent_invoice_payments_agent_select on public.dv_agent_invoice_payments for select to authenticated
using (exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
revoke all on public.dv_agent_invoice_daily_sequences from anon,authenticated;
grant select,insert on public.dv_agent_invoices to authenticated;
grant select,insert on public.dv_agent_invoice_payments to authenticated;
