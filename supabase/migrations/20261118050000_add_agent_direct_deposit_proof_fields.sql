ALTER TABLE public.dv_accounting_agent_bank_details
  ADD COLUMN IF NOT EXISTS proof_storage_path text,
  ADD COLUMN IF NOT EXISTS proof_file_name text,
  ADD COLUMN IF NOT EXISTS proof_uploaded_at timestamptz;
