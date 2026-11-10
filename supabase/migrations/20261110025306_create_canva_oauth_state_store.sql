create table if not exists public.dv_accounting_canva_oauth_states (
  state_hash text primary key,
  code_verifier text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create index if not exists idx_dv_accounting_canva_oauth_states_expires_at
  on public.dv_accounting_canva_oauth_states (expires_at);

alter table public.dv_accounting_canva_oauth_states enable row level security;
revoke all on table public.dv_accounting_canva_oauth_states from anon, authenticated;
grant all on table public.dv_accounting_canva_oauth_states to service_role;
