-- 0032_transaction_type.sql
-- Explicitly distinguishes buy/sell from lease transactions.
alter table public.dv_accounting_transactions
  add column if not exists transaction_type text not null default 'BUY_SELL'
  check (transaction_type in ('BUY_SELL','LEASE'));

create index if not exists dv_tx_transaction_type_idx
  on public.dv_accounting_transactions(transaction_type);
