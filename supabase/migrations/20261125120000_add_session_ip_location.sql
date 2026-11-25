alter table public.dv_accounting_active_sessions
  add column if not exists ip_address text,
  add column if not exists ip_location text,
  add column if not exists ip_lookup_at timestamptz;

comment on column public.dv_accounting_active_sessions.ip_address is
  'Public client IP observed by the authenticated session tracking Edge Function.';
comment on column public.dv_accounting_active_sessions.ip_location is
  'Approximate city, region, and country derived from the public IP address; may be unavailable or inaccurate.';
comment on column public.dv_accounting_active_sessions.ip_lookup_at is
  'Timestamp of the last IP geolocation lookup.';
