alter table public.dv_accounting_transactions
  add column if not exists preconstruction_excluded_amount numeric(14,2);

comment on column public.dv_accounting_transactions.preconstruction_excluded_amount
  is 'Combined pre-HST value of extras/upgrades excluded from a pre-construction builder commission calculation.';
