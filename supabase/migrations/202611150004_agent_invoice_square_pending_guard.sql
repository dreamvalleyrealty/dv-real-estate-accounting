-- Allow only one active Square checkout link per agent invoice.
-- Checkout reuses the pending link until Square confirms payment.
create unique index if not exists uq_dv_agent_invoice_square_one_pending
  on public.dv_agent_invoice_square_sessions(invoice_id)
  where status = 'PENDING';
