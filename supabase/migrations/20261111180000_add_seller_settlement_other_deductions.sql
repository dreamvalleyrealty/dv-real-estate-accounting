-- Add the seller settlement field used by the Seller Settlement form.
alter table public.dv_accounting_seller_settlements
  add column if not exists other_deductions_amount numeric(14,2) not null default 0;

comment on column public.dv_accounting_seller_settlements.other_deductions_amount
  is 'Additional seller settlement deductions beyond commissions and HST.';

notify pgrst, 'reload schema';
