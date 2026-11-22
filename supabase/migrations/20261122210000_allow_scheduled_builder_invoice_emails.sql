-- Allow scheduled pre-construction builder invoice emails.
do $$
declare
  constraint_row record;
begin
  for constraint_row in
    select c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'dv_accounting_scheduled_emails'
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%document_type%'
  loop
    execute format('alter table public.dv_accounting_scheduled_emails drop constraint %I', constraint_row.conname);
  end loop;
end $$;

alter table public.dv_accounting_scheduled_emails
  add constraint dv_accounting_scheduled_emails_document_type_check
  check (document_type = any (array[
    'COMMISSION_INVOICE'::text,
    'PRECONSTRUCTION_BUILDER_INVOICE'::text,
    'SELLER_COMMISSION_STATEMENT'::text
  ]));
