do $$
declare t text;
begin
 foreach t in array array[
  'dv_agent_invoices',
  'dv_agent_invoice_items',
  'dv_agent_invoice_payments',
  'dv_agent_invoice_refunds',
  'dv_agent_invoice_payment_submissions',
  'dv_agent_invoice_square_sessions'
 ] loop
  execute format('drop trigger if exists dv_accounting_audit_trigger on public.%I',t);
  execute format('create trigger dv_accounting_audit_trigger after insert or update or delete on public.%I for each row execute function public.dv_accounting_capture_audit_log()',t);
 end loop;
end $$;