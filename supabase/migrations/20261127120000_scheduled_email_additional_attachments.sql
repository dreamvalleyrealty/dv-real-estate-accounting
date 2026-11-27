alter table public.dv_accounting_scheduled_emails
  add column if not exists additional_attachments jsonb not null default '[]'::jsonb;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'dv_accounting_scheduled_emails_additional_attachments_check'
      and conrelid = 'public.dv_accounting_scheduled_emails'::regclass
  ) then
    alter table public.dv_accounting_scheduled_emails
      add constraint dv_accounting_scheduled_emails_additional_attachments_check
      check (
        jsonb_typeof(additional_attachments) = 'array'
        and jsonb_array_length(additional_attachments) <= 14
      );
  end if;
end $$;