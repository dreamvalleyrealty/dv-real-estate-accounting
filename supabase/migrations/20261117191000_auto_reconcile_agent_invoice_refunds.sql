create or replace function public.dv_reconcile_agent_invoice_refund() returns trigger language plpgsql security definer set search_path=public as $$
declare v_invoice_id uuid; v_total numeric(12,2); v_gross_paid numeric(12,2); v_refunded numeric(12,2); v_net_paid numeric(12,2);
begin
 v_invoice_id:=coalesce(new.invoice_id,old.invoice_id);
 select total_amount into v_total from public.dv_agent_invoices where id=v_invoice_id for update;
 if not found then return null; end if;
 select coalesce(sum(amount),0) into v_gross_paid from public.dv_agent_invoice_payments where invoice_id=v_invoice_id;
 select coalesce(sum(r.amount),0) into v_refunded from public.dv_agent_invoice_refunds r join public.dv_agent_invoice_payments p on p.id=r.invoice_payment_id where p.invoice_id=v_invoice_id and r.status='COMPLETED';
 v_net_paid:=greatest(0,v_gross_paid-v_refunded);
 if v_gross_paid>0 and v_net_paid<=0 then
  update public.dv_agent_invoices set paid_amount=0,balance_amount=0,status='Refunded',updated_at=now() where id=v_invoice_id;
 else
  update public.dv_agent_invoices set paid_amount=v_net_paid,balance_amount=greatest(0,v_total-v_net_paid),status=case when v_net_paid>=v_total then 'Paid' when v_net_paid>0 then 'Partially Paid' else 'Open' end,updated_at=now() where id=v_invoice_id and status<>'Void';
 end if;
 return null;
end $$;
drop trigger if exists trg_dv_reconcile_agent_invoice_refund on public.dv_agent_invoice_refunds;
create trigger trg_dv_reconcile_agent_invoice_refund after insert or update of status,amount on public.dv_agent_invoice_refunds for each row execute function public.dv_reconcile_agent_invoice_refund();