-- 0035 repair transaction workspace tables
-- Ensures every column used by the six-tab transaction editor exists in live databases.

ALTER TABLE public.dv_accounting_transaction_people
  ADD COLUMN IF NOT EXISTS contact_id uuid,
  ADD COLUMN IF NOT EXISTS person_type text DEFAULT 'BUYER',
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name text,
  ADD COLUMN IF NOT EXISTS company_name text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS fax text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS unit text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS province text DEFAULT 'ON',
  ADD COLUMN IF NOT EXISTS postal_code text;

ALTER TABLE public.dv_accounting_transaction_outside_brokers
  ADD COLUMN IF NOT EXISTS brokerage_id uuid,
  ADD COLUMN IF NOT EXISTS company_name text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS fax text,
  ADD COLUMN IF NOT EXISTS agent_name text,
  ADD COLUMN IF NOT EXISTS agent_email text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS unit text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS province text DEFAULT 'ON',
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS billing_email text,
  ADD COLUMN IF NOT EXISTS charges_hst boolean DEFAULT true;

ALTER TABLE public.dv_accounting_transaction_conditions
  ADD COLUMN IF NOT EXISTS item_type text DEFAULT 'CONDITION',
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS due_date date,
  ADD COLUMN IF NOT EXISTS met_date date,
  ADD COLUMN IF NOT EXISTS notes text;

ALTER TABLE public.dv_accounting_transaction_trust
  ADD COLUMN IF NOT EXISTS we_hold_deposit text DEFAULT 'YES',
  ADD COLUMN IF NOT EXISTS held_by text,
  ADD COLUMN IF NOT EXISTS received text DEFAULT 'NO',
  ADD COLUMN IF NOT EXISTS deposit_date date,
  ADD COLUMN IF NOT EXISTS received_from text,
  ADD COLUMN IF NOT EXISTS amount numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trust_bank_account_id uuid,
  ADD COLUMN IF NOT EXISTS earns_interest text DEFAULT 'NO',
  ADD COLUMN IF NOT EXISTS payment_type text DEFAULT 'CHEQUE',
  ADD COLUMN IF NOT EXISTS reference_number text;

ALTER TABLE public.dv_accounting_transaction_commissions
  ADD COLUMN IF NOT EXISTS side text DEFAULT 'LISTING',
  ADD COLUMN IF NOT EXISTS calculation_type text DEFAULT 'PERCENT',
  ADD COLUMN IF NOT EXISTS rate numeric(9,4) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS amount numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS hst_rate numeric(6,3) DEFAULT 13,
  ADD COLUMN IF NOT EXISTS hst_amount numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS settlement_direction text DEFAULT 'RECEIVABLE',
  ADD COLUMN IF NOT EXISTS brokerage_id uuid,
  ADD COLUMN IF NOT EXISTS notes text;

ALTER TABLE public.dv_accounting_transaction_agent_info
  ADD COLUMN IF NOT EXISTS agent_id uuid,
  ADD COLUMN IF NOT EXISTS split_percent numeric(7,3) DEFAULT 90,
  ADD COLUMN IF NOT EXISTS admin_fee numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS lead_fee numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS desk_fee numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS other_outstanding_fees numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS agent_gross numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS net_payable numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS notes text;

NOTIFY pgrst, 'reload schema';
