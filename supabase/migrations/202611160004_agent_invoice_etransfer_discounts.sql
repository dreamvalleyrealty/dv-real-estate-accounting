-- Track e-transfer discounts separately from cash payments so discounted
-- settlements close the invoice without overstating cash received.

alter table public.dv_agent_invoices
  add column if not exists discount_amount numeric(14,2) not null default 0
  check (discount_amount >= 0);

alter table public.dv_agent_invoice_payment_submissions
  add column if not exists discount_amount numeric(14,2) not null default 0
  check (discount_amount >= 0),
  add column if not exists discount_percentage numeric(7,4) not null default 0
  check (discount_percentage between 0 and 100);

-- Reconcile stored invoice balances against invoice totals and recorded payments.
update public.dv_agent_invoices i
set discount_amount = coalesce((
      select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id
    ),0),
    balance_amount = greatest(i.total_amount - i.paid_amount - coalesce((
      select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id
    ),0),0),
    status = case
      when i.paid_amount + coalesce((select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id),0) >= i.total_amount then 'Paid'
      when i.paid_amount + coalesce((select sum(d.amount) from public.dv_agent_invoice_discounts d where d.invoice_id=i.id),0) > 0 then 'Partially Paid'
      when i.due_date is not null and i.due_date < current_date then 'Overdue'
      else 'Open'
    end,
    updated_at = now();

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
  select coalesce(sum(ra.amount),0) into v_refunded
    from public.dv_agent_invoice_refund_allocations ra
    join public.dv_agent_invoice_refunds r on r.id = ra.refund_id
    where ra.invoice_id = v_invoice_id and r.status = 'COMPLETED';
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

create or replace function public.dv_agent_invoice_refresh_refund_allocations()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_id uuid;
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_refunded numeric(14,2);
  v_discount numeric(14,2);
  v_due date;
begin
  for v_id in
    select distinct invoice_id
      from public.dv_agent_invoice_refund_allocations
      where refund_id = new.id
  loop
    select total_amount, due_date into v_total, v_due
      from public.dv_agent_invoices where id = v_id for update;
    select coalesce(sum(amount),0) into v_paid
      from public.dv_agent_invoice_payments where invoice_id = v_id;
    select coalesce(sum(ra.amount),0) into v_refunded
      from public.dv_agent_invoice_refund_allocations ra
      join public.dv_agent_invoice_refunds r on r.id = ra.refund_id
      where ra.invoice_id = v_id and r.status = 'COMPLETED';
    select coalesce(sum(amount),0) into v_discount
      from public.dv_agent_invoice_discounts where invoice_id = v_id;
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
      where id = v_id;
  end loop;
  return new;
end;
$$;

create or replace function public.dv_confirm_agent_invoice_etransfer_submission(p_submission_id uuid)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_submission public.dv_agent_invoice_payment_submissions%rowtype;
  v_item jsonb;
  v_result jsonb;
  v_amount numeric(14,2);
  v_payment numeric(14,2);
  v_discount numeric(14,2);
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
    v_amount := round(coalesce((v_item->>'amount')::numeric,0),2);
    v_payment := round(coalesce((v_item->>'payment_amount')::numeric,v_amount),2);
    v_discount := round(coalesce((v_item->>'discount_amount')::numeric,0),2);
    if v_amount <= 0 or v_payment <= 0 or v_discount < 0
       or v_payment + v_discount <> v_amount then
      raise exception 'The e-transfer payment and discount allocation does not balance';
    end if;
  end loop;

  v_result := public.dv_record_agent_invoice_multi_payment(
    v_submission.agent_id,
    (select jsonb_agg(jsonb_build_object(
      'invoice_id', value->>'invoice_id',
      'amount', coalesce(value->>'payment_amount', value->>'amount'),
      'card_fee_amount', 0,
      'card_fee_tax', 0
    )) from jsonb_array_elements(v_submission.allocations)),
    'E-transfer',
    current_date,
    v_submission.reference_number,
    null,
    'E-transfer verified by management. Discount recorded separately; cash payment allocated oldest invoice first.'
  );

  for v_item in select value from jsonb_array_elements(v_submission.allocations) loop
    v_discount := round(coalesce((v_item->>'discount_amount')::numeric,0),2);
    if v_discount > 0 then
      insert into public.dv_agent_invoice_discounts(invoice_id, submission_id, amount, percentage)
      values ((v_item->>'invoice_id')::uuid, v_submission.id, v_discount, v_submission.discount_percentage)
      on conflict (submission_id, invoice_id) do nothing;
    end if;
  end loop;

  update public.dv_agent_invoice_payment_submissions
    set status = 'CONFIRMED', reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_submission_id;
  return jsonb_build_object('ok',true,'allocations',v_result,'discount_amount',v_submission.discount_amount);
end;
$$;

revoke all on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) from public, anon;
grant execute on function public.dv_confirm_agent_invoice_etransfer_submission(uuid) to authenticated;
