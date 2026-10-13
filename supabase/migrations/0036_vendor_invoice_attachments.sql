-- 0036: Vendor invoice attachments and A/P invoice details.
alter table public.dv_accounting_expenses
 add column if not exists invoice_number text,
 add column if not exists due_date date,
 add column if not exists invoice_storage_path text,
 add column if not exists invoice_file_name text,
 add column if not exists invoice_content_type text,
 add column if not exists invoice_uploaded_at timestamptz;
create index if not exists dv_accounting_expenses_due_date_idx
 on public.dv_accounting_expenses(due_date) where payment_status is distinct from 'PAID';
create index if not exists dv_accounting_expenses_invoice_number_idx
 on public.dv_accounting_expenses(company_id,invoice_number) where invoice_number is not null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dv-vendor-invoices','dv-vendor-invoices',false,20971520,array['application/pdf','image/jpeg','image/png'])
on conflict(id) do update set public=false,file_size_limit=20971520,allowed_mime_types=array['application/pdf','image/jpeg','image/png'];

drop policy if exists "vendor invoice authenticated read" on storage.objects;
create policy "vendor invoice authenticated read" on storage.objects for select to authenticated
 using(bucket_id='dv-vendor-invoices');
drop policy if exists "vendor invoice authenticated upload" on storage.objects;
create policy "vendor invoice authenticated upload" on storage.objects for insert to authenticated
 with check(bucket_id='dv-vendor-invoices' and (storage.foldername(name))[1] is not null);
drop policy if exists "vendor invoice authenticated update" on storage.objects;
create policy "vendor invoice authenticated update" on storage.objects for update to authenticated
 using(bucket_id='dv-vendor-invoices') with check(bucket_id='dv-vendor-invoices');
drop policy if exists "vendor invoice authenticated delete" on storage.objects;
create policy "vendor invoice authenticated delete" on storage.objects for delete to authenticated
 using(bucket_id='dv-vendor-invoices');
