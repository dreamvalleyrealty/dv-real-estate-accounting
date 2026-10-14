-- Normalize nullable inputs for transaction commission approval fields.
-- Both columns are NOT NULL and use zero when the commission is not approved.
create or replace function public.dv_accounting_normalize_commission_approved_amount()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.commission_approved_amount is null then
    new.commission_approved_amount := 0;
  end if;

  if new.commission_approved_agent_payable is null then
    new.commission_approved_agent_payable := 0;
  end if;

  return new;
end;
$$;

drop trigger if exists dv_accounting_normalize_commission_approved_amount
  on public.dv_accounting_transactions;

create trigger dv_accounting_normalize_commission_approved_amount
before insert or update on public.dv_accounting_transactions
for each row
execute function public.dv_accounting_normalize_commission_approved_amount();