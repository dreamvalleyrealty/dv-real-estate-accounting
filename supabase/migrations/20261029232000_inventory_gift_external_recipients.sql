alter table public.dv_accounting_inventory_movements
  add column if not exists recipient_name text,
  add column if not exists recipient_organization text,
  add column if not exists recipient_contact text;

comment on column public.dv_accounting_inventory_movements.recipient_name is 'Name of an external gift recipient when the recipient is not an agent.';
comment on column public.dv_accounting_inventory_movements.recipient_organization is 'Company or organization associated with an inventory gift recipient.';
comment on column public.dv_accounting_inventory_movements.recipient_contact is 'Optional email or phone for an inventory gift recipient.';