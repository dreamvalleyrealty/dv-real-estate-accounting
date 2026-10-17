-- Normalize trade representation-side values to the two supported accounting commission sides.
-- Trade submissions use SELLER/BUYER/LANDLORD/TENANT, while the accounting
-- commission table intentionally supports only LISTING/BUYER.
create or replace function public.dv_accounting_normalize_transaction_commission_side()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.side := case upper(coalesce(new.side, ''))
    when 'SELLER' then 'LISTING'
    when 'LANDLORD' then 'LISTING'
    when 'LISTING' then 'LISTING'
    when 'TENANT' then 'BUYER'
    when 'BUYER' then 'BUYER'
    else new.side
  end;
  return new;
end;
$$;

drop trigger if exists dv_accounting_normalize_transaction_commission_side_trg
  on public.dv_accounting_transaction_commissions;

create trigger dv_accounting_normalize_transaction_commission_side_trg
before insert or update of side
on public.dv_accounting_transaction_commissions
for each row
execute function public.dv_accounting_normalize_transaction_commission_side();
