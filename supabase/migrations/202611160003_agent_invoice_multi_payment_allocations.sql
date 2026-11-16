-- Multi-invoice agent invoice payments.
-- A single Square charge is allocated oldest invoice first. Refunds can be
-- allocated in reverse order without losing the source payment history.

alter table public.dv_agent_invoice_square_sessions
  add column if not exists allocations jsonb not null default '[]'::jsonb,
  add column if not exists base_amount_cents bigint not null default 0,
  add column if not exists fee_amount_cents bigint not null default 0,
  add column if not exists fee_tax_cents bigint not null default 0;

alter table public.dv_agent_invoice_payment_submissions
  add column if not exists allocations jsonb not null default '[]'::jsonb;

alter table public.dv_agent_invoice_payments
  add column if not exists card_fee_amount numeric(14,2) not null default 0,
  add column if not exists card_fee_tax numeric(14,2) not null default 0;

create table if not exists public.dv_agent_invoice_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.dv_agent_invoice_payments(id) on delete restrict,
  invoice_id uuid not null references public.dv_agent_invoices(id) on delete restrict,
  square_payment_id text,
  allocation_order integer not null,
  amount numeric(14,2) not null check (amount > 0),
  card_fee_amount numeric(14,2) not null default 0,
  card_fee_tax numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  unique(payment_id, invoice_id)
);
create index if not exists idx_dv_invoice_allocations_invoice
  on public.dv_agent_invoice_payment_allocations(invoice_id, allocation_order);

create table if not exists public.dv_agent_invoice_refunds (
  id uuid primary key default gen_random_uuid(),
  invoice_payment_id uuid not null references public.dv_agent_invoice_payments(id) on delete restrict,
  square_refund_id text unique,
  amount numeric(14,2) not null check (amount > 0),
  reason text not null,
  status text not null default 'PENDING' check (status in ('PENDING','COMPLETED','FAILED','REJECTED')),
  requested_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists idx_dv_agent_invoice_refunds_payment
  on public.dv_agent_invoice_refunds(invoice_payment_id, created_at desc);

alter table public.dv_agent_invoice_payment_allocations enable row level security;
alter table public.dv_agent_invoice_refunds enable row level security;
revoke all on public.dv_agent_invoice_payment_allocations from anon, authenticated;
revoke all on public.dv_agent_invoice_refunds from anon, authenticated;
grant select on public.dv_agent_invoice_refunds to authenticated;
drop policy if exists dv_agent_invoice_refunds_management_read on public.dv_agent_invoice_refunds;
create policy dv_agent_invoice_refunds_management_read on public.dv_agent_invoice_refunds
  for select to authenticated using (public.dv_is_management_user());

create or replace function public.dv_record_agent_invoice_multi_payment(
  p_agent_id uuid,
  p_allocations jsonb,
  p_payment_method text,
  p_payment_date date,
  p_reference_number text default null,
  p_square_payment_id text default null,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_item jsonb;
  v_invoice public.dv_agent_invoices%rowtype;
  v_amount numeric(14,2);
  v_fee numeric(14,2);
  v_fee_tax numeric(14,2);
  v_payment_id uuid;
  v_first boolean := true;
  v_order integer := 0;
  v_result jsonb := '[]'::jsonb;
begin
  if p_agent_id is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'Payment allocation details are required';
  end if;
  if p_payment_method not in ('Square','E-transfer','Credit card (Square)') then
    raise exception 'Unsupported invoice payment method';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_order := v_order + 1;
    v_amount := round((v_item->>'amount')::numeric,2);
    v_fee := round(coalesce((v_item->>'card_fee_amount')::numeric,0),2);
    v_fee_tax := round(coalesce((v_item->>'card_fee_tax')::numeric,0),2);
    if v_amount <= 0 or v_fee < 0 or v_fee_tax < 0 then
      raise exception 'Invalid payment allocation amount';
    end if;
    select * into v_invoice
      from public.dv_agent_invoices
      where id = (v_item->>'invoice_id')::uuid
        and agent_id = p_agent_id
      for update;
    if not found or v_invoice.status = 'Void' then
      raise exception 'An allocated invoice is no longer payable';
    end if;
    if v_amount > v_invoice.balance_amount then
      raise exception 'An invoice balance changed before payment was recorded. Please retry checkout.';
    end if;

    insert into public.dv_agent_invoice_payments(
      invoice_id, agent_id, amount, payment_date, payment_method,
      reference_number, notes, square_payment_id, card_fee_amount, card_fee_tax
    ) values (
      v_invoice.id, p_agent_id, v_amount, coalesce(p_payment_date,current_date),
      p_payment_method, p_reference_number, p_notes,
      case when v_first then p_square_payment_id else null end, v_fee, v_fee_tax
    ) returning id into v_payment_id;

    insert into public.dv_agent_invoice_payment_allocations(
      payment_id, invoice_id, square_payment_id, allocation_order,
      amount, card_fee_amount, card_fee_tax
    ) values (
      v_payment_id, v_invoice.id, p_square_payment_id, v_order,
      v_amount, v_fee, v_fee_tax
    );

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'invoice_id',v_invoice.id,'payment_id',v_payment_id,
      'amount',v_amount,'card_fee_amount',v_fee,'card_fee_tax',v_fee_tax,
      'allocation_order',v_order
    ));
    v_first := false;
  end loop;
  return v_result;
end;
$$;

revoke all on function public.dv_record_agent_invoice_multi_payment(uuid,jsonb,text,date,text,text,text) from public, anon, authenticated;
grant execute on function public.dv_record_agent_invoice_multi_payment(uuid,jsonb,text,date,text,text,text) to service_role;


alter table public.dv_agent_invoice_refunds
  add column if not exists invoice_id uuid references public.dv_agent_invoices(id) on delete restrict,
  add column if not exists allocations jsonb not null default '[]'::jsonb;

create table if not exists public.dv_agent_invoice_refund_allocations (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.dv_agent_invoice_refunds(id) on delete restrict,
  payment_id uuid not null references public.dv_agent_invoice_payments(id) on delete restrict,
  invoice_id uuid not null references public.dv_agent_invoices(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  allocation_order integer not null,
  created_at timestamptz not null default now(),
  unique(refund_id,invoice_id)
);
create index if not exists idx_dv_invoice_refund_allocations_invoice
  on public.dv_agent_invoice_refund_allocations(invoice_id);
alter table public.dv_agent_invoice_refund_allocations enable row level security;
revoke all on public.dv_agent_invoice_refund_allocations from anon, authenticated;

create or replace function public.dv_agent_invoice_refresh_balance()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_invoice_id uuid;
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_refunded numeric(14,2);
  v_due date;
begin
  v_invoice_id:=case when tg_table_name='dv_agent_invoice_refunds' then coalesce(new.invoice_id,old.invoice_id) else coalesce(new.invoice_id,old.invoice_id) end;
  select total_amount,due_date into v_total,v_due from public.dv_agent_invoices where id=v_invoice_id for update;
  if not found then if tg_op='DELETE' then return old; else return new; end if; end if;
  select coalesce(sum(amount),0) into v_paid from public.dv_agent_invoice_payments where invoice_id=v_invoice_id;
  select coalesce(sum(ra.amount),0) into v_refunded
    from public.dv_agent_invoice_refund_allocations ra
    join public.dv_agent_invoice_refunds r on r.id=ra.refund_id
    where ra.invoice_id=v_invoice_id and r.status='COMPLETED';
  v_paid:=greatest(v_paid-v_refunded,0);
  update public.dv_agent_invoices
    set paid_amount=v_paid,balance_amount=greatest(v_total-v_paid,0),
      status=case when v_paid>=v_total then 'Paid' when v_paid>0 then 'Partially Paid' when due_date is not null and due_date<current_date then 'Overdue' else 'Open' end,
      updated_at=now()
    where id=v_invoice_id;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists trg_dv_agent_invoice_refund_balance on public.dv_agent_invoice_refunds;
create trigger trg_dv_agent_invoice_refund_balance
  after update of status on public.dv_agent_invoice_refunds
  for each row execute function public.dv_agent_invoice_refresh_balance();


create or replace function public.dv_agent_invoice_refresh_refund_allocations()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  for v_id in
    select distinct invoice_id from public.dv_agent_invoice_refund_allocations where refund_id=new.id
  loop
    perform 1 from public.dv_agent_invoices where id=v_id for update;
    update public.dv_agent_invoices i
      set paid_amount=greatest(coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
          - coalesce((select sum(ra.amount) from public.dv_agent_invoice_refund_allocations ra join public.dv_agent_invoice_refunds r on r.id=ra.refund_id where ra.invoice_id=i.id and r.status='COMPLETED'),0),0),
        balance_amount=greatest(i.total_amount-greatest(coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
          - coalesce((select sum(ra.amount) from public.dv_agent_invoice_refund_allocations ra join public.dv_agent_invoice_refunds r on r.id=ra.refund_id where ra.invoice_id=i.id and r.status='COMPLETED'),0),0),0),
        status=case
          when greatest(coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
            - coalesce((select sum(ra.amount) from public.dv_agent_invoice_refund_allocations ra join public.dv_agent_invoice_refunds r on r.id=ra.refund_id where ra.invoice_id=i.id and r.status='COMPLETED'),0),0)>=i.total_amount then 'Paid'
          when greatest(coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
            - coalesce((select sum(ra.amount) from public.dv_agent_invoice_refund_allocations ra join public.dv_agent_invoice_refunds r on r.id=ra.refund_id where ra.invoice_id=i.id and r.status='COMPLETED'),0),0)>0 then 'Partially Paid'
          when i.due_date is not null and i.due_date<current_date then 'Overdue' else 'Open' end,
        updated_at=now()
      where i.id=v_id;
  end loop;
  return new;
end;
$$;
drop trigger if exists trg_dv_agent_invoice_refund_balance on public.dv_agent_invoice_refunds;
create trigger trg_dv_agent_invoice_refund_balance
  after update of status on public.dv_agent_invoice_refunds
  for each row execute function public.dv_agent_invoice_refresh_refund_allocations();


create or replace function public.dv_confirm_agent_invoice_etransfer_submission(p_submission_id uuid)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_submission public.dv_agent_invoice_payment_submissions%rowtype;
  v_result jsonb;
begin
  if not public.dv_is_management_user() then
    raise exception 'Only management users can confirm invoice payments';
  end if;
  select * into v_submission
    from public.dv_agent_invoice_payment_submissions
    where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if v_submission.status='CONFIRMED' then
    return jsonb_build_object('ok',true,'already_confirmed',true);
  end if;
  if v_submission.status<>'PENDING' then
    raise exception 'Only pending e-transfer submissions can be confirmed';
  end if;
  if jsonb_typeof(v_submission.allocations)<>'array' or jsonb_array_length(v_submission.allocations)=0 then
    raise exception 'This payment submission has no saved invoice allocation. Record it manually after verifying the deposit.';
  end if;
  v_result:=public.dv_record_agent_invoice_multi_payment(
    v_submission.agent_id,
    (select jsonb_agg(jsonb_build_object('invoice_id',value->>'invoice_id','amount',value->>'amount','card_fee_amount',0,'card_fee_tax',0)) from jsonb_array_elements(v_submission.allocations)),
    'E-transfer',
    current_date,
    v_submission.reference_number,
    null,
    'E-transfer verified by management. Allocated oldest outstanding invoice first.'
  );
  update public.dv_agent_invoice_payment_submissions
    set status='CONFIRMED',reviewed_by=auth.uid(),reviewed_at=now()
    where id=p_submission_id;
  return jsonb_build_object('ok',true,'allocations',v_result);
end;
$$;
revoke all on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) from public,anon;
grant execute on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) to authenticated;
