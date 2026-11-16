alter table public.dv_agent_invoices alter column agent_id drop not null;
alter table public.dv_agent_invoices add column if not exists bill_to_type text not null default 'AGENT';
alter table public.dv_agent_invoices add column if not exists bill_to_name text;
alter table public.dv_agent_invoices add column if not exists bill_to_company text;
alter table public.dv_agent_invoices add column if not exists bill_to_email text;
alter table public.dv_agent_invoices add column if not exists bill_to_phone text;
alter table public.dv_agent_invoices add column if not exists bill_to_address text;
alter table public.dv_agent_invoices add column if not exists bill_to_city text;
alter table public.dv_agent_invoices add column if not exists bill_to_province text;
alter table public.dv_agent_invoices add column if not exists bill_to_postal_code text;
alter table public.dv_agent_invoice_payments alter column agent_id drop not null;
alter table public.dv_agent_invoice_square_sessions alter column agent_id drop not null;
alter table public.dv_agent_invoices add constraint dv_agent_invoices_bill_to_type_check check (bill_to_type in ('AGENT','OTHER'));
create or replace function public.dv_create_agent_invoice_with_items(p_invoice jsonb,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $function$
declare v_invoice_id uuid; v_line jsonb; v_item_id uuid; v_agent_id uuid;
begin
 if not public.dv_is_management_user() then raise exception 'Only management users can create invoices'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one invoice item is required'; end if;
 v_agent_id:=nullif(p_invoice->>'agent_id','')::uuid;
 if coalesce(p_invoice->>'bill_to_type','AGENT')='AGENT' then
  if v_agent_id is null then raise exception 'Select an agent'; end if;
 elsif coalesce(p_invoice->>'bill_to_type','AGENT')='OTHER' then
  if length(trim(coalesce(p_invoice->>'bill_to_name','')))=0 or length(trim(coalesce(p_invoice->>'bill_to_email','')))=0 then raise exception 'Name and email are required for an external bill-to'; end if;
 else raise exception 'Invalid bill-to type'; end if;
 insert into public.dv_agent_invoices(agent_id,bill_to_type,bill_to_name,bill_to_company,bill_to_email,bill_to_phone,bill_to_address,bill_to_city,bill_to_province,bill_to_postal_code,invoice_date,due_date,description,subtotal,tax_rate,tax_amount,total_amount,paid_amount,balance_amount,status,notes,created_by)
 values(v_agent_id,coalesce(p_invoice->>'bill_to_type','AGENT'),nullif(trim(p_invoice->>'bill_to_name'),''),nullif(trim(p_invoice->>'bill_to_company'),''),nullif(trim(p_invoice->>'bill_to_email'),''),nullif(trim(p_invoice->>'bill_to_phone'),''),nullif(trim(p_invoice->>'bill_to_address'),''),nullif(trim(p_invoice->>'bill_to_city'),''),nullif(trim(p_invoice->>'bill_to_province'),''),nullif(trim(p_invoice->>'bill_to_postal_code'),''),coalesce((p_invoice->>'invoice_date')::date,current_date),nullif(p_invoice->>'due_date','')::date,p_invoice->>'description',(p_invoice->>'subtotal')::numeric,coalesce((p_invoice->>'tax_rate')::numeric,13),(p_invoice->>'tax_amount')::numeric,(p_invoice->>'total_amount')::numeric,0,(p_invoice->>'total_amount')::numeric,'Open',nullif(p_invoice->>'notes',''),auth.uid()) returning id into v_invoice_id;
 for v_line in select value from jsonb_array_elements(p_items) loop
  v_item_id:=nullif(v_line->>'inventory_item_id','')::uuid;
  if v_item_id is null then
   if coalesce(v_line->>'item_code','')<>'CUSTOM' or length(trim(coalesce(v_line->>'item_name','')))=0 then raise exception 'Custom invoice lines require a description and CUSTOM item code'; end if;
  elsif not exists(select 1 from public.dv_accounting_inventory_items inv where inv.id=v_item_id and inv.is_active=true and inv.item_type in ('SELLABLE','SERVICE','GIFT')) then raise exception 'An invoice item is no longer available in Inventory Control'; end if;
  insert into public.dv_agent_invoice_items(invoice_id,inventory_item_id,item_code,item_name,line_type,quantity,unit_price,tax_rate,line_subtotal,line_tax,line_total)
  values(v_invoice_id,v_item_id,nullif(v_line->>'item_code',''),v_line->>'item_name',coalesce(v_line->>'line_type','ITEM'),(v_line->>'quantity')::numeric,(v_line->>'unit_price')::numeric,(v_line->>'tax_rate')::numeric,(v_line->>'line_subtotal')::numeric,(v_line->>'line_tax')::numeric,(v_line->>'line_total')::numeric);
 end loop;
 return v_invoice_id;
end;$function$;