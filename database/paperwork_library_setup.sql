-- Dream Valley Realty: official paperwork reference library
-- Run this setup script in the Supabase SQL Editor for the DV-Back-Office project.

create table if not exists public.dv_accounting_paperwork_library (
  id uuid primary key default gen_random_uuid(),
  document_name text not null check (length(btrim(document_name)) > 0),
  category text not null default 'OTHER',
  version text not null check (length(btrim(version)) > 0),
  effective_date date,
  status text not null default 'DRAFT' check (status in ('DRAFT','PUBLISHED','ARCHIVED')),
  storage_path text not null unique,
  original_file_name text not null,
  mime_type text not null default 'application/pdf' check (mime_type = 'application/pdf'),
  file_size bigint not null default 0 check (file_size >= 0),
  validation_rules jsonb not null default '[]'::jsonb check (jsonb_typeof(validation_rules) = 'array'),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  constraint dv_accounting_paperwork_library_name_version_unique unique (document_name, version)
);

create index if not exists dv_accounting_paperwork_library_status_category_idx
  on public.dv_accounting_paperwork_library (status, category, document_name);

alter table public.dv_accounting_paperwork_library enable row level security;

grant select, insert, update, delete on public.dv_accounting_paperwork_library to authenticated;

drop policy if exists "paperwork library published or admin read" on public.dv_accounting_paperwork_library;
create policy "paperwork library published or admin read"
  on public.dv_accounting_paperwork_library
  for select to authenticated
  using (
    status = 'PUBLISHED'
    or public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );

drop policy if exists "paperwork library admins insert" on public.dv_accounting_paperwork_library;
create policy "paperwork library admins insert"
  on public.dv_accounting_paperwork_library
  for insert to authenticated
  with check (
    public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
    and (created_by is null or created_by = auth.uid())
  );

drop policy if exists "paperwork library admins update" on public.dv_accounting_paperwork_library;
create policy "paperwork library admins update"
  on public.dv_accounting_paperwork_library
  for update to authenticated
  using (
    public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  )
  with check (
    public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );

drop policy if exists "paperwork library admins delete" on public.dv_accounting_paperwork_library;
create policy "paperwork library admins delete"
  on public.dv_accounting_paperwork_library
  for delete to authenticated
  using (
    public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );

-- Private bucket: only authenticated users can read published reference forms;
-- only authorized management roles can upload, replace or delete reference files.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dv-paperwork-reference', 'dv-paperwork-reference', false, 20971520, array['application/pdf'])
on conflict (id) do update
set public = false,
    file_size_limit = 20971520,
    allowed_mime_types = array['application/pdf'];

drop policy if exists "paperwork reference published or admin read" on storage.objects;
create policy "paperwork reference published or admin read"
  on storage.objects
  for select to authenticated
  using (
    bucket_id = 'dv-paperwork-reference'
    and (
      exists (
        select 1
        from public.dv_accounting_paperwork_library l
        where l.storage_path = objects.name
          and l.status = 'PUBLISHED'
      )
      or public.dv_accounting_current_user_role() = any (
        array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
      )
    )
  );

drop policy if exists "paperwork reference admins upload" on storage.objects;
create policy "paperwork reference admins upload"
  on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'dv-paperwork-reference'
    and public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );

drop policy if exists "paperwork reference admins update" on storage.objects;
create policy "paperwork reference admins update"
  on storage.objects
  for update to authenticated
  using (
    bucket_id = 'dv-paperwork-reference'
    and public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  )
  with check (
    bucket_id = 'dv-paperwork-reference'
    and public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );

drop policy if exists "paperwork reference admins delete" on storage.objects;
create policy "paperwork reference admins delete"
  on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'dv-paperwork-reference'
    and public.dv_accounting_current_user_role() = any (
      array['SUPERADMIN','ADMIN','BROKER_OF_RECORD','BROKER','MANAGER','MANAGEMENT','OWNER']::text[]
    )
  );
