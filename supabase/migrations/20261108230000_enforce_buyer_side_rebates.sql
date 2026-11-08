-- Enforce that buyer rebates can only be recorded against a closed buyer-side trade.
-- This protects the accounting workflow even if a request bypasses the browser UI.

create or replace function public.dv_accounting_validate_buyer_rebate_trade()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_side text;
  v_status text;
begin
  select upper(coalesce(t.side,'')), upper(coalesce(t.status,''))
    into v_side, v_status
  from public.dv_accounting_transactions t
  where t.id = new.transaction_id
    and t.company_id = new.company_id;

  if not found then
    raise exception 'Buyer rebate must be linked to a transaction in the same company.';
  end if;

  if v_side <> 'BUYER' then
    raise exception 'Buyer rebates are only permitted when the brokerage represents the buyer.';
  end if;

  if v_status <> 'CLOSED' then
    raise exception 'Buyer rebates can only be recorded for closed buyer-side trades.';
  end if;

  return new;
end;
$$;

drop trigger if exists dv_accounting_buyer_rebate_trade_check
  on public.dv_accounting_buyer_rebates;

create trigger dv_accounting_buyer_rebate_trade_check
before insert or update of company_id, transaction_id
on public.dv_accounting_buyer_rebates
for each row
execute function public.dv_accounting_validate_buyer_rebate_trade();
