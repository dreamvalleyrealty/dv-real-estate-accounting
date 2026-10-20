-- Scheduled email queue, owner-scoped access, and minute-by-minute worker trigger.
create table if not exists public.dv_accounting_scheduled_email_worker_auth (
  id boolean primary key default true check (id),
  worker_token text not null,
  created_at timestamptz not null default now()
);
alter table public.dv_accounting_scheduled_email_worker_auth enable row level security;
revoke all on public.dv_accounting_scheduled_email_worker_auth from anon, authenticated;
insert into public.dv_accounting_scheduled_email_worker_auth (id, worker_token)
values (true, encode(gen_random_bytes(32), 'hex'))
on conflict (id) do nothing;

alter table public.dv_accounting_scheduled_emails
  add column if not exists updated_at timestamptz not null default now();
alter table public.dv_accounting_scheduled_emails
  add column if not exists attempts integer not null default 0;
alter table public.dv_accounting_scheduled_emails enable row level security;

drop policy if exists "Users can view their scheduled emails" on public.dv_accounting_scheduled_emails;
create policy "Users can view their scheduled emails"
  on public.dv_accounting_scheduled_emails for select to authenticated
  using (created_by = auth.uid());
drop policy if exists "Users can schedule their own emails" on public.dv_accounting_scheduled_emails;
create policy "Users can schedule their own emails"
  on public.dv_accounting_scheduled_emails for insert to authenticated
  with check (created_by = auth.uid() and status = 'SCHEDULED');
drop policy if exists "Users can cancel their own scheduled emails" on public.dv_accounting_scheduled_emails;
create policy "Users can cancel their own scheduled emails"
  on public.dv_accounting_scheduled_emails for update to authenticated
  using (created_by = auth.uid() and status = 'SCHEDULED')
  with check (created_by = auth.uid() and status = 'CANCELLED');

create index if not exists dv_accounting_scheduled_emails_due_idx
  on public.dv_accounting_scheduled_emails (scheduled_at)
  where status = 'SCHEDULED';

select cron.unschedule(jobid) from cron.job where jobname = 'dv-accounting-send-scheduled-emails';
select cron.schedule(
  'dv-accounting-send-scheduled-emails',
  '* * * * *',
  $job$
  select net.http_post(
    url := 'https://bjriisauroukyuhbfkuh.supabase.co/functions/v1/zoho-scheduled-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-worker-token', (select worker_token from public.dv_accounting_scheduled_email_worker_auth where id = true)
    ),
    body := '{}'::jsonb
  );
  $job$
);
