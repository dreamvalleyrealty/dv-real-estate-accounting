-- When an agent commission is confirmed PAID with an issued cheque/EFT reference,
-- the transaction should be CLOSED, not left in a separate PAID status.
create or replace function public.dv_accounting_sync_paid_commission_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction_id uuid;
begin
  if upper(coalesce(new.status,'')) <> 'PAID' then
    return new;
  end if;

  if not exists (
    select 1
      from public.dv_accounting_commission_cheques ch
     where ch.commission_id = new.id
       and upper(coalesce(ch.status,'')) = 'ISSUED'
       and nullif(btrim(coalesce(ch.payment_reference, ch.cheque_number, '')), '') is not null
  ) then
    return new;
  end if;

  v_transaction_id := new.transaction_id;
  if v_transaction_id is not null then
    update public.dv_accounting_transactions
       set status = 'CLOSED',
           commission_payroll_status = 'PAID',
           closed_at = coalesce(closed_at, now())
     where id = v_transaction_id
       and upper(coalesce(status,'')) not in ('DFT','RETURNED')
       and (
         upper(coalesce(status,'')) <> 'CLOSED'
         or upper(coalesce(commission_payroll_status,'')) <> 'PAID'
       );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_paid_commission_transaction on public.dv_accounting_commissions;
create trigger trg_sync_paid_commission_transaction
after insert or update of status on public.dv_accounting_commissions
for each row
execute function public.dv_accounting_sync_paid_commission_transaction();

-- Repair already-paid agent commissions so their transactions show CLOSED.
-- Preserve DFT/RETURNED trades and do not alter any accounting entries.
with verified_paid as (
  select distinct c.transaction_id
    from public.dv_accounting_commissions c
    join public.dv_accounting_commission_cheques ch on ch.commission_id = c.id
   where upper(coalesce(c.status,'')) = 'PAID'
     and upper(coalesce(ch.status,'')) = 'ISSUED'
     and nullif(btrim(coalesce(ch.payment_reference, ch.cheque_number, '')), '') is not null
     and c.transaction_id is not null
)
update public.dv_accounting_transactions t
   set status = 'CLOSED',
       commission_payroll_status = 'PAID',
       closed_at = coalesce(t.closed_at, now())
  from verified_paid p
 where t.id = p.transaction_id
   and upper(coalesce(t.status,'')) not in ('DFT','RETURNED')
   and (
     upper(coalesce(t.status,'')) <> 'CLOSED'
     or upper(coalesce(t.commission_payroll_status,'')) <> 'PAID'
   );
