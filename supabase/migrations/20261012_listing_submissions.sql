-- Listing submission workflow: agent paperwork, admin approval, and REALM MLS tracking.
create table if not exists public.dv_accounting_listing_submissions (
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id) on delete set null,
 agent_id uuid not null references public.dv_accounting_agents(id) on delete restrict,
 property_address text not null,
 unit_number text not null default '',
 city text not null,
 province text not null default 'ON',
 postal_code text not null default '',
 property_type text not null default 'RESIDENTIAL',
 listing_type text not null default 'SALE' check (listing_type in ('SALE','LEASE')),
 asking_price numeric(14,2),
 listing_start_date date,
 listing_expiry_date date,
 notes text not null default '',
 status text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED','PUBLISHED')),
 mls_number text,
 admin_notes text not null default '',
 created_by uuid references auth.users(id) on delete set null,
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 published_at timestamptz
);
create index if not exists idx_dv_listing_submissions_agent on public.dv_accounting_listing_submissions(agent_id,created_at desc);
create index if not exists idx_dv_listing_submissions_status on public.dv_accounting_listing_submissions(status,created_at desc);
create unique index if not exists idx_dv_listing_submissions_mls_unique on public.dv_accounting_listing_submissions(upper(mls_number)) where mls_number is not null and btrim(mls_number)<>'';
alter table public.dv_accounting_listing_submissions enable row level security;
drop policy if exists "listing submissions admin read" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin read" on public.dv_accounting_listing_submissions for select to authenticated using (public.dv_accounting_is_trade_admin());
drop policy if exists "listing submissions agent read own" on public.dv_accounting_listing_submissions;
create policy "listing submissions agent read own" on public.dv_accounting_listing_submissions for select to authenticated using (exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists "listing submissions agent create own" on public.dv_accounting_listing_submissions;
create policy "listing submissions agent create own" on public.dv_accounting_listing_submissions for insert to authenticated with check (created_by=auth.uid() and status='DRAFT' and exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists "listing submissions agent update draft" on public.dv_accounting_listing_submissions;
create policy "listing submissions agent update draft" on public.dv_accounting_listing_submissions for update to authenticated using (status in ('DRAFT','NEEDS_CHANGES') and exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email',''))))) with check (status in ('DRAFT','NEEDS_CHANGES','SUBMITTED') and exists(select 1 from public.dv_accounting_agents a where a.id=agent_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists "listing submissions admin update" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin update" on public.dv_accounting_listing_submissions for update to authenticated using (public.dv_accounting_is_trade_admin()) with check (public.dv_accounting_is_trade_admin());

create table if not exists public.dv_accounting_listing_documents (
 id uuid primary key default gen_random_uuid(),
 listing_id uuid not null references public.dv_accounting_listing_submissions(id) on delete restrict,
 document_type text not null,
 document_name text not null,
 storage_path text not null unique,
 mime_type text,
 file_size bigint,
 uploaded_by uuid references auth.users(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now()
);
create index if not exists idx_dv_listing_documents_listing on public.dv_accounting_listing_documents(listing_id,created_at desc);
alter table public.dv_accounting_listing_documents enable row level security;
drop policy if exists "listing documents admin read" on public.dv_accounting_listing_documents;
create policy "listing documents admin read" on public.dv_accounting_listing_documents for select to authenticated using (public.dv_accounting_is_trade_admin());
drop policy if exists "listing documents agent read own" on public.dv_accounting_listing_documents;
create policy "listing documents agent read own" on public.dv_accounting_listing_documents for select to authenticated using (exists(select 1 from public.dv_accounting_listing_submissions s join public.dv_accounting_agents a on a.id=s.agent_id where s.id=listing_id and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists "listing documents agent insert own" on public.dv_accounting_listing_documents;
create policy "listing documents agent insert own" on public.dv_accounting_listing_documents for insert to authenticated with check (uploaded_by=auth.uid() and exists(select 1 from public.dv_accounting_listing_submissions s join public.dv_accounting_agents a on a.id=s.agent_id where s.id=listing_id and s.status in ('DRAFT','NEEDS_CHANGES') and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email','')))));
drop policy if exists "listing documents admin insert" on public.dv_accounting_listing_documents;
create policy "listing documents admin insert" on public.dv_accounting_listing_documents for insert to authenticated with check (public.dv_accounting_is_trade_admin() and uploaded_by=auth.uid());
drop policy if exists "listing documents admin delete" on public.dv_accounting_listing_documents;
create policy "listing documents admin delete" on public.dv_accounting_listing_documents for delete to authenticated using (public.dv_accounting_is_trade_admin());

insert into storage.buckets(id,name,public) values('dv-trade-documents','dv-trade-documents',false) on conflict(id) do update set public=false;
drop policy if exists "listing storage agent insert" on storage.objects;
create policy "listing storage agent insert" on storage.objects for insert to authenticated with check (
 bucket_id='dv-trade-documents' and (storage.foldername(name))[1]='listings'
 and exists(select 1 from public.dv_accounting_listing_submissions s join public.dv_accounting_agents a on a.id=s.agent_id where s.id=((storage.foldername(name))[2])::uuid and s.status in ('DRAFT','NEEDS_CHANGES') and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
);
drop policy if exists "listing storage agent read" on storage.objects;
create policy "listing storage agent read" on storage.objects for select to authenticated using (
 bucket_id='dv-trade-documents' and (storage.foldername(name))[1]='listings'
 and exists(select 1 from public.dv_accounting_listing_submissions s join public.dv_accounting_agents a on a.id=s.agent_id where s.id=((storage.foldername(name))[2])::uuid and lower(trim(a.email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
);
drop policy if exists "listing storage admin read" on storage.objects;
create policy "listing storage admin read" on storage.objects for select to authenticated using (bucket_id='dv-trade-documents' and (storage.foldername(name))[1]='listings' and public.dv_accounting_is_trade_admin());
drop policy if exists "listing storage admin insert" on storage.objects;
create policy "listing storage admin insert" on storage.objects for insert to authenticated with check (bucket_id='dv-trade-documents' and (storage.foldername(name))[1]='listings' and public.dv_accounting_is_trade_admin());
drop policy if exists "listing storage admin delete" on storage.objects;
create policy "listing storage admin delete" on storage.objects for delete to authenticated using (bucket_id='dv-trade-documents' and (storage.foldername(name))[1]='listings' and public.dv_accounting_is_trade_admin());

-- Default configurable listing paperwork checklist; admins may customize it in Settings.
insert into public.dv_accounting_settings(company_id,key,value)
select c.id,'LISTING_DOCUMENT_REQUIREMENTS',
'[{"code":"LISTING_AGREEMENT","label":"Listing Agreement","required":true},{"code":"MLS_DATA","label":"MLS Data / Listing Information","required":true},{"code":"PROPERTY_DETAILS","label":"Property Details / Feature Sheet","required":true},{"code":"SELLER_DIRECTION","label":"Seller Direction / Authorization","required":true},{"code":"ID_FINTRAC","label":"Identification / FINTRAC","required":true},{"code":"OTHER","label":"Other Supporting Documents","required":false}]'::jsonb
from public.dv_accounting_companies c
on conflict (company_id,key) do nothing;
