CREATE INDEX IF NOT EXISTS dv_accounting_audit_log_changed_at_id_idx
ON public.dv_accounting_audit_log (changed_at DESC, id DESC);
