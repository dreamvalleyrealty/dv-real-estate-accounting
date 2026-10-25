-- Store the address for authorized lawyer and third-party seller settlement payments.
alter table public.dv_accounting_seller_settlement_payments
  add column if not exists payee_address text;
