create table if not exists public.dv_open_house_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid references public.dv_accounting_agents(id) on delete set null,
  created_by uuid not null default auth.uid() references auth.users(id),
  property_address text not null check (length(btrim(property_address)) > 0),
  property_lat double precision,
  property_lng double precision,
  event_date date,
  start_time time,
  end_time time,
  status text not null default 'PLANNED' check (status in ('PLANNED','ACTIVE','COMPLETED','CANCELLED')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dv_open_house_sign_locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  created_by uuid not null default auth.uid() references auth.users(id),
  label text not null default 'Directional sign',
  address text not null,
  latitude double precision not null,
  longitude double precision not null,
  direction text,
  notes text,
  photo_path text,
  active boolean not null default true,
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dv_open_house_sign_locations_latitude_check check (latitude between -90 and 90),
  constraint dv_open_house_sign_locations_longitude_check check (longitude between -180 and 180)
);

create table if not exists public.dv_open_house_event_signs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  event_id uuid not null references public.dv_open_house_events(id) on delete cascade,
  sign_location_id uuid not null references public.dv_open_house_sign_locations(id) on delete restrict,
  sequence integer not null default 1,
  status text not null default 'PLANNED' check (status in ('PLANNED','INSTALLED','COLLECTED')),
  installed_at timestamptz,
  installed_by uuid references auth.users(id),
  collected_at timestamptz,
  collected_by uuid references auth.users(id),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, sign_location_id)
);

create index if not exists dv_open_house_events_company_date_idx
  on public.dv_open_house_events (company_id, event_date desc);
create index if not exists dv_open_house_sign_locations_company_idx
  on public.dv_open_house_sign_locations (company_id, active);
create index if not exists dv_open_house_sign_locations_geo_idx
  on public.dv_open_house_sign_locations (company_id, latitude, longitude);
create index if not exists dv_open_house_event_signs_event_idx
  on public.dv_open_house_event_signs (event_id, sequence);

alter table public.dv_open_house_events enable row level security;
alter table public.dv_open_house_sign_locations enable row level security;
alter table public.dv_open_house_event_signs enable row level security;

grant select, insert, update, delete on public.dv_open_house_events to authenticated;
grant select, insert, update, delete on public.dv_open_house_sign_locations to authenticated;
grant select, insert, update, delete on public.dv_open_house_event_signs to authenticated;

drop policy if exists "open house events company read" on public.dv_open_house_events;
create policy "open house events company read" on public.dv_open_house_events
  for select to authenticated
  using (exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_events.company_id
  ));

drop policy if exists "open house events create in own company" on public.dv_open_house_events;
create policy "open house events create in own company" on public.dv_open_house_events
  for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_events.company_id
    )
  );

drop policy if exists "open house events update own or admin" on public.dv_open_house_events;
create policy "open house events update own or admin" on public.dv_open_house_events
  for update to authenticated
  using (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_events.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  )
  with check (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_events.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  );

drop policy if exists "open house events delete own or admin" on public.dv_open_house_events;
create policy "open house events delete own or admin" on public.dv_open_house_events
  for delete to authenticated
  using (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_events.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  );

drop policy if exists "open house sign locations company read" on public.dv_open_house_sign_locations;
create policy "open house sign locations company read" on public.dv_open_house_sign_locations
  for select to authenticated
  using (exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_sign_locations.company_id
  ));

drop policy if exists "open house sign locations create in own company" on public.dv_open_house_sign_locations;
create policy "open house sign locations create in own company" on public.dv_open_house_sign_locations
  for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_sign_locations.company_id
    )
  );

drop policy if exists "open house sign locations update own or admin" on public.dv_open_house_sign_locations;
create policy "open house sign locations update own or admin" on public.dv_open_house_sign_locations
  for update to authenticated
  using (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_sign_locations.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  )
  with check (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_sign_locations.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  );

drop policy if exists "open house sign locations delete own or admin" on public.dv_open_house_sign_locations;
create policy "open house sign locations delete own or admin" on public.dv_open_house_sign_locations
  for delete to authenticated
  using (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_sign_locations.company_id
    )
    and (created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
  );

drop policy if exists "open house event signs company read" on public.dv_open_house_event_signs;
create policy "open house event signs company read" on public.dv_open_house_event_signs
  for select to authenticated
  using (exists (
    select 1 from public.dv_accounting_user_profiles p
    where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_event_signs.company_id
  ));

drop policy if exists "open house event signs manage own event or admin" on public.dv_open_house_event_signs;
create policy "open house event signs manage own event or admin" on public.dv_open_house_event_signs
  for all to authenticated
  using (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_event_signs.company_id
    )
    and exists (
      select 1 from public.dv_open_house_events e
      where e.id = dv_open_house_event_signs.event_id
        and e.company_id = dv_open_house_event_signs.company_id
        and (e.created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
    )
  )
  with check (
    exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true and p.company_id = dv_open_house_event_signs.company_id
    )
    and exists (
      select 1 from public.dv_open_house_events e
      where e.id = dv_open_house_event_signs.event_id
        and e.company_id = dv_open_house_event_signs.company_id
        and (e.created_by = (select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dv-open-house-sign-photos', 'dv-open-house-sign-photos', false, 8388608, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = false, file_size_limit = 8388608,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic'];

drop policy if exists "open house sign photos company read" on storage.objects;
create policy "open house sign photos company read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'dv-open-house-sign-photos'
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true
        and p.company_id::text = (storage.foldername(name))[1]
    )
  );

drop policy if exists "open house sign photos company insert" on storage.objects;
create policy "open house sign photos company insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'dv-open-house-sign-photos'
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true
        and p.company_id::text = (storage.foldername(name))[1]
    )
  );

drop policy if exists "open house sign photos company update" on storage.objects;
create policy "open house sign photos company update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'dv-open-house-sign-photos'
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true
        and p.company_id::text = (storage.foldername(name))[1]
    )
  )
  with check (
    bucket_id = 'dv-open-house-sign-photos'
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true
        and p.company_id::text = (storage.foldername(name))[1]
    )
  );

drop policy if exists "open house sign photos company delete" on storage.objects;
create policy "open house sign photos company delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'dv-open-house-sign-photos'
    and exists (
      select 1 from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid()) and p.active = true
        and p.company_id::text = (storage.foldername(name))[1]
    )
  );
