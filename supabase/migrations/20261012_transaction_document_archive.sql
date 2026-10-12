-- Retain transaction evidence for the life of the trade record, including after closing.
create table if not exists public.dv_accounting_transaction_documents (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.dv_accounting_transactions(id) on delete restrict,
  company_id uuid references public.dv_accounting_companies(id) on delete set null,
  document_type text not null default 'OTHER',
  document_name text not null,
  storage_path text not null unique,
  mime_type text,
  file_size bigint,
  notes text,
  uploaded_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists idx_transaction_documents_transaction
  on public.dv_accounting_transaction_documents(transaction_id, created_at desc);

alter table public.dv_accounting_transaction_documents enable row level security;
drop policy if exists "transaction documents admin read" on public.dv_accounting_transaction_documents;
create policy "transaction documents admin read" on public.dv_accounting_transaction_documents
for select to authenticated using (public.dv_accounting_is_trade_admin());
drop policy if exists "transaction documents admin insert" on public.dv_accounting_transaction_documents;
create policy "transaction documents admin insert" on public.dv_accounting_transaction_documents
for insert to authenticated with check (public.dv_accounting_is_trade_admin() and uploaded_by = auth.uid());
drop policy if exists "transaction documents admin update" on public.dv_accounting_transaction_documents;
create policy "transaction documents admin update" on public.dv_accounting_transaction_documents
for update to authenticated using (public.dv_accounting_is_trade_admin()) with check (public.dv_accounting_is_trade_admin());
drop policy if exists "transaction documents admin delete" on public.dv_accounting_transaction_documents;
create policy "transaction documents admin delete" on public.dv_accounting_transaction_documents
for delete to authenticated using (public.dv_accounting_is_trade_admin());

-- Keep the shared trade-document bucket private; access is via authenticated policies and signed URLs.
insert into storage.buckets (id, name, public)
values ('dv-trade-documents', 'dv-trade-documents', false)
on conflict (id) do update set public = false;

drop policy if exists "transaction archive storage read" on storage.objects;
create policy "transaction archive storage read" on storage.objects
for select to authenticated using (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = 'transactions'
  and public.dv_accounting_is_trade_admin()
);
drop policy if exists "transaction archive storage insert" on storage.objects;
create policy "transaction archive storage insert" on storage.objects
for insert to authenticated with check (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = 'transactions'
  and public.dv_accounting_is_trade_admin()
);
drop policy if exists "transaction archive storage delete" on storage.objects;
create policy "transaction archive storage delete" on storage.objects
for delete to authenticated using (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = 'transactions'
  and public.dv_accounting_is_trade_admin()
);

comment on table public.dv_accounting_transaction_documents is
  'Long-term evidence file register for real-estate transaction management and audit retrieval. Transaction deletion is restricted while files exist.';

-- Backfill documents already attached to approved submissions into the transaction archive index.
insert into public.dv_accounting_transaction_documents
  (transaction_id, document_type, document_name, storage_path, mime_type, file_size, uploaded_by, created_at)
select d.transaction_id, d.document_type, d.document_name, d.storage_path, d.mime_type, d.file_size, d.uploaded_by, d.created_at
from public.dv_accounting_agent_trade_documents d
where d.transaction_id is not null
on conflict (storage_path) do nothing;
