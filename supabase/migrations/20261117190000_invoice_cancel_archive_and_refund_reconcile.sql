alter table public.dv_agent_invoices add column if not exists archived_at timestamptz, add column if not exists archived_by uuid;
alter table public.dv_agent_invoices drop constraint if exists dv_agent_invoices_status_check;
alter table public.dv_agent_invoices add constraint dv_agent_invoices_status_check check (status = any (array['Open','Partially Paid','Paid','Overdue','Void','Refunded']::text[]));
create or replace function public.dv_cancel_agent_invoice(p_invoice_id uuid,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare v_invoice public.dv_agent_invoices%rowtype;
begin
 if not public.dv_is_management_user() then raise exception 'Only management users can cancel invoices'; end if;
 if coalesce(trim(p_reason),'')='' then raise exception 'A cancellation reason is required'; end if;
 select * into v_invoice from public.dv_agent_invoices where id=p_invoice_id for update;
 if not found then raise exception 'Invoice not found'; end if;
 if v_invoice.status in ('Void','Refunded') then raise exception 'This invoice is already cancelled or refunded'; end if;
 if exists(select 1 from public.dv_agent_invoice_payments where invoice_id=p_invoice_id) then raise exception 'This invoice has payment history. Refund or reconcile the payment before cancelling it.'; end if;
 update public.dv_agent_invoices set status='Void',balance_amount=0,notes=concat_ws(E'\\n',nullif(notes,''),'Cancelled: '||trim(p_reason)),updated_at=now() where id=p_invoice_id;
end $$;
create or replace function public.dv_archive_refunded_agent_invoice(p_invoice_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare v_invoice public.dv_agent_invoices%rowtype;
begin
 if not public.dv_is_management_user() then raise exception 'Only management users can archive invoices'; end if;
 select * into v_invoice from public.dv_agent_invoices where id=p_invoice_id for update;
 if not found then raise exception 'Invoice not found'; end if;
 if v_invoice.status <> 'Refunded' or coalesce(v_invoice.balance_amount,0) <> 0 then raise exception 'Only fully refunded invoices with zero balance can be archived'; end if;
 update public.dv_agent_invoices set archived_at=now(),archived_by=auth.uid(),updated_at=now() where id=p_invoice_id;
end $$;
update public.dv_agent_invoices i set status='Refunded',balance_amount=0,paid_amount=0,updated_at=now()
where i.invoice_number='2026111501' and i.id='6cf96f86-d252-4384-aec6-67045d6468c6'
and exists(select 1 from public.dv_agent_invoice_payments p join public.dv_agent_invoice_refunds r on r.invoice_payment_id=p.id where p.invoice_id=i.id group by p.id,p.amount having sum(case when r.status='COMPLETED' then r.amount else 0 end)>=p.amount);