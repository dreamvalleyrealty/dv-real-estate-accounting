-- Invoice line items linked to the existing inventory catalogue.
create table if not exists public.dv_agent_invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.dv_agent_invoices(id) on delete cascade,
  inventory_item_id uuid references public.dv_accounting_inventory_items(id) on delete set null,
  item_code text,
  item_name text not null,
  line_type text not null default 'ITEM' check (line_type in ('ITEM','ADD_ON')),
  quantity numeric(12,2) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  tax_rate numeric(7,4) not null default 13 check (tax_rate >= 0),
  line_subtotal numeric(14,2) not null check (line_subtotal >= 0),
  line_tax numeric(14,2) not null check (line_tax >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);
create index if not exists idx_dv_agent_invoice_items_invoice
  on public.dv_agent_invoice_items(invoice_id, created_at);

alter table public.dv_agent_invoice_items enable row level security;
drop policy if exists dv_agent_invoice_items_management_all on public.dv_agent_invoice_items;
create policy dv_agent_invoice_items_management_all on public.dv_agent_invoice_items
  for all to authenticated using (public.dv_is_management_user())
  with check (public.dv_is_management_user());
drop policy if exists dv_agent_invoice_items_agent_select on public.dv_agent_invoice_items;
create policy dv_agent_invoice_items_agent_select on public.dv_agent_invoice_items
  for select to authenticated using (
    exists (
      select 1 from public.dv_agent_invoices i
      join public.dv_accounting_agents a on a.id=i.agent_id
      where i.id=invoice_id
        and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))
    )
  );
grant select,insert on public.dv_agent_invoice_items to authenticated;

-- Create the invoice and all its lines in one transaction.
create or replace function public.dv_create_agent_invoice_with_items(
  p_invoice jsonb,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_invoice_id uuid;
  v_line jsonb;
  v_item_id uuid;
begin
  if not public.dv_is_management_user() then
    raise exception 'Only management users can create agent invoices';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'At least one invoice item is required';
  end if;

  insert into public.dv_agent_invoices (
    agent_id,invoice_date,due_date,description,subtotal,tax_rate,tax_amount,
    total_amount,paid_amount,balance_amount,status,notes,created_by
  ) values (
    (p_invoice->>'agent_id')::uuid,
    coalesce((p_invoice->>'invoice_date')::date,current_date),
    nullif(p_invoice->>'due_date','')::date,
    p_invoice->>'description',
    (p_invoice->>'subtotal')::numeric,
    coalesce((p_invoice->>'tax_rate')::numeric,13),
    (p_invoice->>'tax_amount')::numeric,
    (p_invoice->>'total_amount')::numeric,
    0,
    (p_invoice->>'total_amount')::numeric,
    'Open',
    nullif(p_invoice->>'notes',''),
    auth.uid()
  ) returning id into v_invoice_id;

  for v_line in select value from jsonb_array_elements(p_items)
  loop
    v_item_id := nullif(v_line->>'inventory_item_id','')::uuid;
    if v_item_id is null or not exists (
      select 1 from public.dv_accounting_inventory_items inv
      where inv.id=v_item_id and inv.is_active=true
        and inv.item_type in ('SELLABLE','SERVICE','GIFT')
    ) then
      raise exception 'An invoice item is no longer available in Inventory Control';
    end if;

    insert into public.dv_agent_invoice_items (
      invoice_id,inventory_item_id,item_code,item_name,line_type,quantity,
      unit_price,tax_rate,line_subtotal,line_tax,line_total
    ) values (
      v_invoice_id,v_item_id,
      nullif(v_line->>'item_code',''),
      v_line->>'item_name',
      coalesce(v_line->>'line_type','ITEM'),
      (v_line->>'quantity')::numeric,
      (v_line->>'unit_price')::numeric,
      (v_line->>'tax_rate')::numeric,
      (v_line->>'line_subtotal')::numeric,
      (v_line->>'line_tax')::numeric,
      (v_line->>'line_total')::numeric
    );
  end loop;

  return v_invoice_id;
end;
$$;
revoke all on function public.dv_create_agent_invoice_with_items(jsonb,jsonb) from public,anon;
grant execute on function public.dv_create_agent_invoice_with_items(jsonb,jsonb) to authenticated;
