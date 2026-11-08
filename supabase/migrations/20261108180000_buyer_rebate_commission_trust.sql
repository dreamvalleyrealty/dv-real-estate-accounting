-- Buyer rebate disbursements from Commission Trust.
-- Records can be entered and approved without posting money. The posting RPC is a
-- separate, atomic, idempotent action that requires the actual buyer-side trade
-- commission trust funds to be present for the same company, transaction and matter.

create table if not exists public.dv_accounting_buyer_rebates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id),
  transaction_id uuid not null references public.dv_accounting_transactions(id),
  buyer_name text not null check (length(btrim(buyer_name)) > 0),
  amount numeric(14,2) not null check (amount > 0),
  reason text,
  agreement_reference text,
  support_document_paths jsonb not null default '[]'::jsonb,
  status text not null default 'PENDING'
    check (status in ('PENDING','APPROVED','REJECTED','PROCESSED','COMPLETED')),
  approval_notes text,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  payment_date date,
  payment_method text check (payment_method is null or payment_method in ('CHEQUE','EFT')),
  payment_reference text,
  commission_trust_account_id uuid references public.dv_accounting_bank_accounts(id),
  trust_transaction_id uuid references public.dv_accounting_trust_transactions(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint dv_accounting_buyer_rebate_posting_unique unique (trust_transaction_id),
  constraint dv_accounting_buyer_rebate_completed_fields check (
    status <> 'COMPLETED' or
    (approved_at is not null and payment_date is not null and
     payment_method is not null and length(btrim(coalesce(payment_reference,''))) > 0 and
     commission_trust_account_id is not null and trust_transaction_id is not null)
  )
);

create index if not exists dv_accounting_buyer_rebates_transaction_idx
  on public.dv_accounting_buyer_rebates(company_id, transaction_id, created_at desc);
create index if not exists dv_accounting_buyer_rebates_status_idx
  on public.dv_accounting_buyer_rebates(company_id, status, created_at desc);

alter table public.dv_accounting_buyer_rebates enable row level security;
revoke all on public.dv_accounting_buyer_rebates from anon;
grant select, insert, update on public.dv_accounting_buyer_rebates to authenticated;

drop policy if exists "buyer rebates management read" on public.dv_accounting_buyer_rebates;
create policy "buyer rebates management read"
on public.dv_accounting_buyer_rebates for select to authenticated
using (
  company_id in (
    select p.company_id from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid() and p.active = true
  )
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

drop policy if exists "buyer rebates management insert" on public.dv_accounting_buyer_rebates;
create policy "buyer rebates management insert"
on public.dv_accounting_buyer_rebates for insert to authenticated
with check (
  company_id in (
    select p.company_id from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid() and p.active = true
  )
  and created_by = auth.uid()
  and status = 'PENDING'
  and approved_by is null and approved_at is null and trust_transaction_id is null
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

drop policy if exists "buyer rebates management update" on public.dv_accounting_buyer_rebates;
create policy "buyer rebates management update"
on public.dv_accounting_buyer_rebates for update to authenticated
using (
  company_id in (
    select p.company_id from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid() and p.active = true
  )
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
)
with check (
  company_id in (
    select p.company_id from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid() and p.active = true
  )
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

create or replace function public.dv_accounting_guard_buyer_rebate()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role text := public.dv_accounting_current_user_role();
begin
  if tg_op = 'UPDATE' and old.trust_transaction_id is not null then
    if new.company_id is distinct from old.company_id
       or new.transaction_id is distinct from old.transaction_id
       or new.buyer_name is distinct from old.buyer_name
       or new.amount is distinct from old.amount
       or new.payment_date is distinct from old.payment_date
       or new.payment_method is distinct from old.payment_method
       or new.payment_reference is distinct from old.payment_reference
       or new.commission_trust_account_id is distinct from old.commission_trust_account_id
       or new.trust_transaction_id is distinct from old.trust_transaction_id
       or new.status is distinct from old.status then
      raise exception 'A posted buyer rebate is locked. Use a correcting trust entry rather than editing the payment.';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status = 'APPROVED'
     and new.status not in ('APPROVED','PROCESSED','COMPLETED') then
    raise exception 'An approved rebate cannot be changed back to pending. Reject or document a correction instead.';
  end if;
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by,auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists dv_accounting_buyer_rebate_guard on public.dv_accounting_buyer_rebates;
create trigger dv_accounting_buyer_rebate_guard
before insert or update on public.dv_accounting_buyer_rebates
for each row execute function public.dv_accounting_guard_buyer_rebate();

create or replace function public.dv_accounting_approve_buyer_rebate(
  p_rebate_id uuid, p_approved boolean, p_notes text default null
) returns public.dv_accounting_buyer_rebates
language plpgsql security definer set search_path = public as $$
declare r public.dv_accounting_buyer_rebates%rowtype;
begin
  if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN','MANAGER') then
    raise exception 'Only management can approve or reject buyer rebates.';
  end if;
  select * into r from public.dv_accounting_buyer_rebates where id=p_rebate_id for update;
  if not found then raise exception 'Buyer rebate not found.'; end if;
  if r.trust_transaction_id is not null then raise exception 'This rebate has already been paid and posted.'; end if;
  if r.status not in ('PENDING','APPROVED') then raise exception 'Only pending rebates can be approved or rejected.'; end if;
  update public.dv_accounting_buyer_rebates
  set status=case when p_approved then 'APPROVED' else 'REJECTED' end,
      approval_notes=nullif(btrim(coalesce(p_notes,'')),''),
      approved_by=case when p_approved then auth.uid() else null end,
      approved_at=case when p_approved then now() else null end,
      updated_at=now()
  where id=p_rebate_id returning * into r;
  return r;
end;
$$;

create or replace function public.dv_accounting_post_buyer_rebate(
  p_rebate_id uuid,
  p_payment_date date,
  p_payment_method text,
  p_payment_reference text,
  p_commission_trust_account_id uuid
) returns public.dv_accounting_buyer_rebates
language plpgsql security definer set search_path = public as $$
declare
  r public.dv_accounting_buyer_rebates%rowtype;
  tx public.dv_accounting_transactions%rowtype;
  v_client text;
  v_matter text;
  v_available numeric(14,2);
  v_trust_tx uuid;
begin
  if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT') then
    raise exception 'You are not authorized to post buyer rebate payments.';
  end if;
  if p_payment_date is null or upper(coalesce(p_payment_method,'')) not in ('CHEQUE','EFT')
     or length(btrim(coalesce(p_payment_reference,'')))=0 then
    raise exception 'Payment date, method and cheque/EFT reference are required.';
  end if;
  select * into r from public.dv_accounting_buyer_rebates where id=p_rebate_id for update;
  if not found then raise exception 'Buyer rebate not found.'; end if;
  if r.trust_transaction_id is not null then return r; end if;
  if r.status <> 'APPROVED' then raise exception 'Buyer rebate must be approved before payment.'; end if;
  select * into tx from public.dv_accounting_transactions where id=r.transaction_id;
  if not found or tx.company_id <> r.company_id then raise exception 'Linked transaction/company mismatch.'; end if;
  if upper(coalesce(tx.status,'')) <> 'CLOSED' then raise exception 'Buyer rebates can only be paid after the trade is closed.'; end if;
  if not exists (
    select 1 from public.dv_accounting_bank_accounts ba
    where ba.id=p_commission_trust_account_id and ba.company_id=r.company_id
      and ba.account_type='COMMISSION_TRUST' and ba.active=true
  ) then raise exception 'Select an active Commission Trust account for this company.'; end if;

  -- Find the original Commission Trust credit for this trade, preserving client and matter identity.
  select tt.client_name,tt.matter into v_client,v_matter
  from public.dv_accounting_trust_transactions tt
  where tt.company_id=r.company_id and tt.transaction_id=r.transaction_id
    and tt.bank_account_id=p_commission_trust_account_id
    and tt.trust_account_type='COMMISSION_TRUST'
    and tt.direction='DEPOSIT' and upper(coalesce(tt.status,''))='POSTED'
    and tt.amount>0
  order by tt.created_at desc limit 1;
  if coalesce(btrim(v_client),'')='' or coalesce(btrim(v_matter),'')='' then
    raise exception 'No posted Commission Trust deposit was found for this trade and account.';
  end if;
  select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0)
  into v_available from public.dv_accounting_trust_liabilities l
  where l.company_id=r.company_id and l.trust_account_type='COMMISSION_TRUST'
    and l.client_name=v_client and l.matter=v_matter;
  if coalesce(v_available,0)+0.005 < r.amount then
    raise exception 'Insufficient posted Commission Trust funds for this trade. Available: %, rebate: %.',coalesce(v_available,0),r.amount;
  end if;

  perform public.dv_accounting_post_trust_transaction(
    r.company_id,p_commission_trust_account_id,r.transaction_id,p_payment_date,
    'COMMISSION_TRUST','DISBURSEMENT',v_client,v_matter,
    'Buyer rebate paid to '||r.buyer_name||' - '||coalesce(tx.transaction_number,v_matter),
    r.amount,p_payment_reference
  );
  select id into v_trust_tx from public.dv_accounting_trust_transactions
  where transaction_id=r.transaction_id and bank_account_id=p_commission_trust_account_id
    and trust_account_type='COMMISSION_TRUST' and direction='DISBURSEMENT'
    and matter=v_matter and reference=p_payment_reference and amount=r.amount
    and upper(coalesce(status,''))='POSTED'
  order by created_at desc limit 1;
  if v_trust_tx is null then raise exception 'Commission Trust disbursement was not confirmed.'; end if;
  update public.dv_accounting_buyer_rebates
  set status='COMPLETED',payment_date=p_payment_date,payment_method=upper(p_payment_method),
      payment_reference=btrim(p_payment_reference),commission_trust_account_id=p_commission_trust_account_id,
      trust_transaction_id=v_trust_tx,completed_at=now(),updated_at=now()
  where id=p_rebate_id returning * into r;
  return r;
end;
$$;

revoke all on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) from public,anon;
grant execute on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) to authenticated;
revoke all on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) from public,anon;
grant execute on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) to authenticated;
