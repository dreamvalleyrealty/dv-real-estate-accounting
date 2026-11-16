-- Configurable e-transfer discounts with separate accounting records.
-- This migration is self-contained for the currently deployed invoice schema.

alter table public.dv_agent_invoices
  add column if not exists discount_amount numeric(14,2) not null default 0
  check (discount_amount >= 0);

alter table public.dv_agent_invoice_payment_submissions
  add column if not exists allocations jsonb not null default '[]'::jsonb,
  add column if not exists discount_amount numeric(14,2) not null default 0
  check (discount_amount >= 0),
  add column if not exists discount_percentage numeric(7,4) not null default 0
  check (discount_percentage between 0 and 100);

create table if not exists public.dv_agent_invoice_discounts (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.dv_agent_invoices(id) on delete restrict,
  submission_id uuid not null references public.dv_agent_invoice_payment_submissions(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  percentage numeric(7,4) not null default 0 check (percentage between 0 and 100),
  created_at timestamptz not null default now(),
  unique(submission_id, invoice_id)
);
create index if not exists idx_dv_agent_invoice_discounts_invoice
  on public.dv_agent_invoice_discounts(invoice_id, created_at desc);
alter table public.dv_agent_invoice_discounts enable row level security;
revoke all on public.dv_agent_invoice_discounts from anon, authenticated;

-- Reconcile stored invoice balances against the actual payment and refund records.
update public.dv_agent_invoices i
set paid_amount = greatest(
      coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
      - coalesce((select sum(r.amount) from public.dv_agent_invoice_refunds r where r.invoice_id=i.id and r.status='COMPLETED'),0),
      0
    ),
    discount_amount = coalesce((
      select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id
    ),0),
    balance_amount = greatest(
      i.total_amount
      - greatest(
          coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
          - coalesce((select sum(r.amount) from public.dv_agent_invoice_refunds r where r.invoice_id=i.id and r.status='COMPLETED'),0),
          0
        )
      - coalesce((select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id),0),
      0
    ),
    status = case
      when greatest(
        coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
        - coalesce((select sum(r.amount) from public.dv_agent_invoice_refunds r where r.invoice_id=i.id and r.status='COMPLETED'),0),
        0
      ) + coalesce((select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id),0) >= i.total_amount then 'Paid'
      when greatest(
        coalesce((select sum(p.amount) from public.dv_agent_invoice_payments p where p.invoice_id=i.id),0)
        - coalesce((select sum(r.amount) from public.dv_agent_invoice_refunds r where r.invoice_id=i.id and r.status='COMPLETED'),0),
        0
      ) + coalesce((select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id),0) > 0 then 'Partially Paid'
      when i.due_date is not null and i.due_date < current_date then 'Overdue'
      else 'Open'
    end,
    updated_at = now();

create or replace function public.dv_agent_invoice_refresh_balance()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_invoice_id uuid;
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_refunded numeric(14,2);
  v_discount numeric(14,2);
  v_due date;
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);
  select total_amount, due_date into v_total, v_due
    from public.dv_agent_invoices where id = v_invoice_id for update;
  if not found then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  select coalesce(sum(amount),0) into v_paid
    from public.dv_agent_invoice_payments where invoice_id = v_invoice_id;
  select coalesce(sum(amount),0) into v_refunded
    from public.dv_agent_invoice_refunds
    where invoice_id = v_invoice_id and status = 'COMPLETED';
  select coalesce(sum(amount),0) into v_discount
    from public.dv_agent_invoice_discounts where invoice_id = v_invoice_id;

  v_paid := greatest(v_paid - v_refunded, 0);
  update public.dv_agent_invoices
    set paid_amount = v_paid,
        discount_amount = v_discount,
        balance_amount = greatest(v_total - v_paid - v_discount, 0),
        status = case
          when v_paid + v_discount >= v_total then 'Paid'
          when v_paid + v_discount > 0 then 'Partially Paid'
          when v_due is not null and v_due < current_date then 'Overdue'
          else 'Open'
        end,
        updated_at = now()
    where id = v_invoice_id;

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists trg_dv_agent_invoice_discount_balance on public.dv_agent_invoice_discounts;
create trigger trg_dv_agent_invoice_discount_balance
  after insert or update or delete on public.dv_agent_invoice_discounts
  for each row execute function public.dv_agent_invoice_refresh_balance();

create or replace function public.dv_confirm_agent_invoice_etransfer_submission(p_submission_id uuid)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_submission public.dv_agent_invoice_payment_submissions%rowtype;
  v_item jsonb;
  v_invoice public.dv_agent_invoices%rowtype;
  v_payment numeric(14,2);
  v_discount numeric(14,2);
  v_gross numeric(14,2);
  v_payment_id uuid;
  v_result jsonb := '[]'::jsonb;
begin
  if not public.dv_is_management_user() then
    raise exception 'Only management users can confirm invoice payments';
  end if;

  select * into v_submission
    from public.dv_agent_invoice_payment_submissions
    where id = p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if v_submission.status = 'CONFIRMED' then
    return jsonb_build_object('ok',true,'already_confirmed',true);
  end if;
  if v_submission.status <> 'PENDING' then
    raise exception 'Only pending e-transfer submissions can be confirmed';
  end if;
  if jsonb_typeof(v_submission.allocations) <> 'array'
     or jsonb_array_length(v_submission.allocations) = 0 then
    raise exception 'This payment submission has no saved invoice allocation. Record it manually after verifying the deposit.';
  end if;

  for v_item in select value from jsonb_array_elements(v_submission.allocations) loop
    v_gross := round(coalesce((v_item->>'amount')::numeric,0),2);
    v_payment := round(coalesce((v_item->>'payment_amount')::numeric,v_gross),2);
    v_discount := round(coalesce((v_item->>'discount_amount')::numeric,0),2);
    if v_gross <= 0 or v_payment <= 0 or v_discount < 0 or v_payment + v_discount <> v_gross then
      raise exception 'The e-transfer payment and discount allocation does not balance';
    end if;

    select * into v_invoice
      from public.dv_agent_invoices
      where id = (v_item->>'invoice_id')::uuid
      for update;
    if not found or v_invoice.status = 'Void' then
      raise exception 'An allocated invoice is no longer payable';
    end if;
    if v_submission.agent_id is not null and v_invoice.agent_id <> v_submission.agent_id then
      raise exception 'An allocated invoice does not belong to this agent';
    end if;
    if v_submission.agent_id is null and v_invoice.id <> v_submission.invoice_id then
      raise exception 'External invoices can only settle their own balance';
    end if;
    if v_gross > v_invoice.balance_amount then
      raise exception 'An invoice balance changed before confirmation. Please review the current balance.';
    end if;

    insert into public.dv_agent_invoice_payments(
      invoice_id, agent_id, amount, payment_date, payment_method,
      reference_number, notes, recorded_by
    ) values (
      v_invoice.id, v_submission.agent_id, v_payment, current_date, 'E-transfer',
      v_submission.reference_number,
      'E-transfer verified by management. Discount recorded separately.',
      auth.uid()
    ) returning id into v_payment_id;

    if v_discount > 0 then
      insert into public.dv_agent_invoice_discounts(invoice_id, submission_id, amount, percentage)
      values (v_invoice.id, v_submission.id, v_discount, v_submission.discount_percentage);
    end if;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'invoice_id',v_invoice.id,'payment_id',v_payment_id,
      'payment_amount',v_payment,'discount_amount',v_discount,'gross_amount',v_gross
    ));
  end loop;

  update public.dv_agent_invoice_payment_submissions
    set status = 'CONFIRMED', reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_submission_id;
  return jsonb_build_object('ok',true,'allocations',v_result,'discount_amount',v_submission.discount_amount);
end;
$$;

revoke all on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) from public, anon;
grant execute on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) to authenticated;
