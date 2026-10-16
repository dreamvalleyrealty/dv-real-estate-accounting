create table if not exists public.dv_accounting_active_sessions (
  session_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  user_agent text
);
create index if not exists dv_accounting_active_sessions_last_seen_idx on public.dv_accounting_active_sessions(last_seen_at desc);
alter table public.dv_accounting_active_sessions enable row level security;
drop policy if exists "users maintain own active session" on public.dv_accounting_active_sessions;
create policy "users maintain own active session" on public.dv_accounting_active_sessions
 for all to authenticated
 using (user_id = auth.uid())
 with check (user_id = auth.uid());
drop policy if exists "superadmins view active sessions" on public.dv_accounting_active_sessions;
create policy "superadmins view active sessions" on public.dv_accounting_active_sessions
 for select to authenticated
 using (exists (select 1 from public.dv_accounting_user_profiles p where p.user_id = auth.uid() and upper(coalesce(p.role,'')) = 'SUPERADMIN' and coalesce(p.active,true) = true));
