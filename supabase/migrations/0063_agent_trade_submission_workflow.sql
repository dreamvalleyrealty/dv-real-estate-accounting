-- 0063: agent trade submission, document review and approval workflow
create or replace function public.dv_accounting_is_trade_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'), false)
$$;

create or replace function public.dv_accounting_my_agent_id()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select a.id
  from public.dv_accounting_agents a
  where lower(trim(coalesce(a.email,''))) = lower(trim(coalesce(auth.jwt()->>'email','')))
  order by a.created_at nulls last
  limit 1
$$;

revoke all on function public.dv_accounting_is_trade_admin() from public, anon;
grant execute on function public.dv_accounting_is_trade_admin() to authenticated;
revoke all on function public.dv_accounting_my_agent_id() from public, anon;
grant execute on function public.dv_accounting_my_agent_id() to authenticated;

create table if not exists public.dv_accounting_agent_trade_submissions (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.dv_accounting_agents(id) on delete restrict,
  submitted_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  status text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED')),
  payload jsonb not null default '{}'::jsonb,
  review_notes text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  transaction_id uuid references public.dv_accounting_transactions(id) on delete set null,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_agent_trade_documents (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.dv_accounting_agent_trade_submissions(id) on delete cascade,
  document_type text not null default 'OTHER',
  document_name text not null,
  storage_path text not null,
  mime_type text,
  file_size bigint,
  extracted_text text,
  match_status text not null default 'PENDING' check (match_status in ('PENDING','MATCH','MISMATCH','NOT_APPLICABLE')),
  match_notes text,
  uploaded_by uuid not null references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists idx_agent_trade_submissions_agent on public.dv_accounting_agent_trade_submissions(agent_id, created_at desc);
create index if not exists idx_agent_trade_submissions_status on public.dv_accounting_agent_trade_submissions(status, submitted_at);
create index if not exists idx_agent_trade_documents_submission on public.dv_accounting_agent_trade_documents(submission_id);

alter table public.dv_accounting_agent_trade_submissions enable row level security;
alter table public.dv_accounting_agent_trade_documents enable row level security;

drop policy if exists "agent trade submission read" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission read" on public.dv_accounting_agent_trade_submissions
for select to authenticated
using (submitted_by = auth.uid() or public.dv_accounting_is_trade_admin());

drop policy if exists "agent trade submission insert" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission insert" on public.dv_accounting_agent_trade_submissions
for insert to authenticated
with check (submitted_by = auth.uid() and agent_id = public.dv_accounting_my_agent_id() and status = 'DRAFT');

drop policy if exists "agent trade submission update" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission update" on public.dv_accounting_agent_trade_submissions
for update to authenticated
using ((submitted_by = auth.uid() and status in ('DRAFT','NEEDS_CHANGES')) or public.dv_accounting_is_trade_admin())
with check ((submitted_by = auth.uid() and status in ('DRAFT','NEEDS_CHANGES','SUBMITTED')) or public.dv_accounting_is_trade_admin());

drop policy if exists "agent trade submission delete" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission delete" on public.dv_accounting_agent_trade_submissions
for delete to authenticated
using (submitted_by = auth.uid() and status = 'DRAFT');

drop policy if exists "agent trade document read" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document read" on public.dv_accounting_agent_trade_documents
for select to authenticated
using (
  public.dv_accounting_is_trade_admin()
  or exists (
    select 1 from public.dv_accounting_agent_trade_submissions s
    where s.id = submission_id and s.submitted_by = auth.uid()
  )
);

drop policy if exists "agent trade document insert" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document insert" on public.dv_accounting_agent_trade_documents
for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (
    select 1 from public.dv_accounting_agent_trade_submissions s
    where s.id = submission_id and s.submitted_by = auth.uid() and s.status in ('DRAFT','NEEDS_CHANGES')
  )
);

drop policy if exists "agent trade document update" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document update" on public.dv_accounting_agent_trade_documents
for update to authenticated
using (public.dv_accounting_is_trade_admin())
with check (public.dv_accounting_is_trade_admin());

drop policy if exists "agent trade document delete" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document delete" on public.dv_accounting_agent_trade_documents
for delete to authenticated
using (
  public.dv_accounting_is_trade_admin()
  or exists (
    select 1 from public.dv_accounting_agent_trade_submissions s
    where s.id = submission_id and s.submitted_by = auth.uid() and s.status in ('DRAFT','NEEDS_CHANGES')
  )
);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'dv-trade-documents','dv-trade-documents',false,26214400,
  array['application/pdf','image/jpeg','image/png','image/tiff','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document']
)
on conflict(id) do update set public=false, file_size_limit=26214400;

drop policy if exists "trade docs upload own folder" on storage.objects;
create policy "trade docs upload own folder" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
  and public.dv_accounting_my_agent_id() is not null
);

drop policy if exists "trade docs read own or admin" on storage.objects;
create policy "trade docs read own or admin" on storage.objects
for select to authenticated
using (
  bucket_id = 'dv-trade-documents'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.dv_accounting_is_trade_admin()
  )
);

drop policy if exists "trade docs delete own draft or admin" on storage.objects;
create policy "trade docs delete own draft or admin" on storage.objects
for delete to authenticated
using (
  bucket_id = 'dv-trade-documents'
  and (
    public.dv_accounting_is_trade_admin()
    or (
      (storage.foldername(name))[1] = auth.uid()::text
      and exists (
        select 1
        from public.dv_accounting_agent_trade_documents d
        join public.dv_accounting_agent_trade_submissions s on s.id = d.submission_id
        where d.storage_path = name and s.submitted_by = auth.uid() and s.status in ('DRAFT','NEEDS_CHANGES')
      )
    )
  )
);

create or replace function public.dv_accounting_approve_agent_trade_submission(p_submission_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions;
  p jsonb;
  new_tx_id uuid;
  buyer text;
  seller text;
  tx_no text;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only the Trade Admin Manager or an administrator can approve trade submissions';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if s.id is null then raise exception 'Trade submission not found'; end if;
  if s.status = 'APPROVED' and s.transaction_id is not null then return s.transaction_id; end if;
  if s.status <> 'SUBMITTED' then raise exception 'Only submitted trades can be approved'; end if;

  p := s.payload;
  buyer := nullif(trim(coalesce(p->>'buyer_name','')), '');
  seller := nullif(trim(coalesce(p->>'seller_name','')), '');
  tx_no := coalesce(nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));

  insert into public.dv_accounting_transactions (
    company_id, transaction_number, status, transaction_date, property_address,
    client_name, side, sale_price, gross_commission, agent_id,
    street_number, street_name, unit_number, city, province, postal_code,
    offer_date, firm_date, close_date, entry_date, mls_number, transaction_type
  )
  values (
    (select a.company_id from public.dv_accounting_agents a where a.id = s.agent_id limit 1),
    tx_no, 'DRAFT',
    nullif(p->>'transaction_date','')::date,
    nullif(trim(coalesce(p->>'property_address','')),''),
    nullif(trim(coalesce(p->>'client_name','')),''),
    nullif(trim(coalesce(p->>'side','')),''),
    coalesce(nullif(p->>'sale_price','')::numeric,0),
    coalesce(nullif(p->>'gross_commission','')::numeric,0),
    s.agent_id,
    nullif(p->>'street_number',''), nullif(p->>'street_name',''), nullif(p->>'unit_number',''),
    nullif(p->>'city',''), coalesce(nullif(p->>'province',''),'ON'), nullif(p->>'postal_code',''),
    nullif(p->>'offer_date','')::date, nullif(p->>'firm_date','')::date, nullif(p->>'close_date','')::date,
    current_date, nullif(p->>'mls_number',''), coalesce(nullif(p->>'transaction_type',''),'BUY_SELL')
  )
  returning id into new_tx_id;

  if buyer is not null then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(new_tx_id,'BUYER',split_part(buyer,' ',1),nullif(substr(buyer,length(split_part(buyer,' ',1))+2),''),nullif(p->>'buyer_company',''),nullif(p->>'buyer_email',''),nullif(p->>'buyer_phone',''));
  end if;
  if seller is not null then
    insert into public.dv_accounting_transaction_people(transaction_id,person_type,first_name,last_name,company_name,email,phone)
    values(new_tx_id,'SELLER',split_part(seller,' ',1),nullif(substr(seller,length(split_part(seller,' ',1))+2),''),nullif(p->>'seller_company',''),nullif(p->>'seller_email',''),nullif(p->>'seller_phone',''));
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status='APPROVED', transaction_id=new_tx_id, reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where id=s.id;

  return new_tx_id;
end;
$$;

revoke all on function public.dv_accounting_approve_agent_trade_submission(uuid) from public, anon;
grant execute on function public.dv_accounting_approve_agent_trade_submission(uuid) to authenticated;

create or replace function public.dv_accounting_review_agent_trade_submission(p_submission_id uuid, p_status text, p_notes text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.dv_accounting_is_trade_admin() then raise exception 'Only the Trade Admin Manager or an administrator can review submissions'; end if;
  if p_status not in ('NEEDS_CHANGES','SUBMITTED') then raise exception 'Invalid review status'; end if;
  update public.dv_accounting_agent_trade_submissions
  set status=p_status, review_notes=nullif(trim(coalesce(p_notes,'')),''), reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where id=p_submission_id and status='SUBMITTED';
  if not found then raise exception 'Submission not found or no longer awaiting review'; end if;
end;
$$;

revoke all on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) from public, anon;
grant execute on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) to authenticated;
