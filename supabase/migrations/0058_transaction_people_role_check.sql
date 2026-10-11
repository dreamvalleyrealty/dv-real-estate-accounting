-- 0058: repair transaction person roles and make People/Brokerage saves deterministic.
ALTER TABLE public.dv_accounting_transaction_people
  DROP CONSTRAINT IF EXISTS dv_accounting_transaction_people_person_type_check;

ALTER TABLE public.dv_accounting_transaction_people
  ADD CONSTRAINT dv_accounting_transaction_people_person_type_check
  CHECK (person_type IN ('BUYER','SELLER','BUYER_SOLICITOR','SELLER_SOLICITOR','OTHER'));

NOTIFY pgrst, 'reload schema';
