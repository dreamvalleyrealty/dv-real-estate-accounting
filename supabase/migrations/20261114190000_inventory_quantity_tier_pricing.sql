-- Quantity-based inventory pricing. Each tier applies its unit price to every unit
-- in the order once its minimum quantity is reached (all-units tier pricing).
alter table public.dv_accounting_inventory_items
  add column if not exists pricing_tiers jsonb not null default '[]'::jsonb;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'dv_accounting_inventory_items_pricing_tiers_array'
      and conrelid = 'public.dv_accounting_inventory_items'::regclass
  ) then
    alter table public.dv_accounting_inventory_items
      add constraint dv_accounting_inventory_items_pricing_tiers_array
      check (jsonb_typeof(pricing_tiers) = 'array');
  end if;
end
$$;

comment on column public.dv_accounting_inventory_items.pricing_tiers is
  'All-units quantity pricing tiers: [{"min_quantity":1,"unit_price":15.00}, ...]. Highest qualifying minimum quantity sets the unit price for every unit in the order.';
