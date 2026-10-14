alter table public.dv_accounting_expense_payments
  add column if not exists payment_method text,
  add column if not exists cheque_number text,
  add column if not exists bank_account_id uuid;

update public.dv_accounting_expense_payments
set payment_method = case
  when coalesce(reference, '') ~* '^(EFT|E-TRANSFER|TRANSFER)' then 'EFT'
  when coalesce(reference, '') <> '' then 'CHEQUE'
  else payment_method
end
where payment_method is null;

create index if not exists dv_accounting_expense_payments_bank_cheque_idx
  on public.dv_accounting_expense_payments (bank_account_id, cheque_number)
  where payment_method = 'CHEQUE';
