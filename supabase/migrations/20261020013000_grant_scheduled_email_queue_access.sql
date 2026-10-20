-- Grant authenticated users the table privileges required by the scheduled-email UI.
grant select, insert, update on public.dv_accounting_scheduled_emails to authenticated;
grant select, insert, update, delete on public.dv_accounting_scheduled_emails to service_role;
