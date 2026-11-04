alter table public.dv_accounting_deposit_receipt_issuances
  add column if not exists approval_status text not null default 'PENDING',
  add column if not exists approved_by uuid null,
  add column if not exists approved_at timestamptz null,
  add column if not exists rejection_reason text null;

alter table public.dv_accounting_deposit_receipt_issuances
  drop constraint if exists dv_accounting_deposit_receipt_issuances_approval_status_check;
alter table public.dv_accounting_deposit_receipt_issuances
  add constraint dv_accounting_deposit_receipt_issuances_approval_status_check
  check (approval_status in ('PENDING','APPROVED','REJECTED'));

create index if not exists idx_dv_deposit_receipt_approval
  on public.dv_accounting_deposit_receipt_issuances (approval_status, issued_at desc);

create or replace function public.dv_accounting_guard_approved_deposit_receipt()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.dv_accounting_current_user_role();
  v_trust_transaction_id uuid;
  v_is_approved boolean := false;
begin
  if TG_TABLE_NAME = 'dv_accounting_deposit_receipt_issuances' then
    if v_role = 'SUPERADMIN' then
      if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
    end if;
    if TG_OP = 'DELETE' then
      if OLD.approval_status = 'APPROVED' then
        raise exception 'Approved deposit receipts are locked. Only a Super Admin can delete or change them.';
      end if;
      return OLD;
    end if;
    if OLD.approval_status = 'APPROVED' then
      raise exception 'Approved deposit receipts are locked. Only a Super Admin can change them.';
    end if;
    if NEW.issued_by is distinct from OLD.issued_by
       or NEW.issuer_name is distinct from OLD.issuer_name
       or NEW.issuer_signature_path is distinct from OLD.issuer_signature_path
       or NEW.trust_transaction_id is distinct from OLD.trust_transaction_id
       or NEW.transaction_id is distinct from OLD.transaction_id
       or NEW.issued_at is distinct from OLD.issued_at then
      raise exception 'Receipt issuer details cannot be changed by staff.';
    end if;
    return NEW;
  end if;

  if v_role = 'SUPERADMIN' then
    if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
  end if;
  if TG_OP = 'DELETE' then v_trust_transaction_id := OLD.transaction_id;
  else v_trust_transaction_id := NEW.transaction_id; end if;

  if v_trust_transaction_id is not null then
    select exists (
      select 1 from public.dv_accounting_deposit_receipt_issuances i
      join public.dv_accounting_trust_transactions t on t.id = i.trust_transaction_id
      where i.transaction_id = v_trust_transaction_id and i.approval_status = 'APPROVED'
    ) into v_is_approved;
    if v_is_approved then
      raise exception 'This deposit receipt has been approved and is locked. Only a Super Admin can make changes.';
    end if;
    if TG_TABLE_NAME = 'dv_accounting_transaction_trust' and TG_OP = 'UPDATE' then
      update public.dv_accounting_deposit_receipt_issuances i
      set approval_status = 'PENDING', approved_by = null, approved_at = null, rejection_reason = null
      where i.transaction_id = v_trust_transaction_id and i.approval_status = 'REJECTED';
    end if;
  end if;
  if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
end;
$$;

drop trigger if exists trg_guard_approved_deposit_receipt_issuance on public.dv_accounting_deposit_receipt_issuances;
create trigger trg_guard_approved_deposit_receipt_issuance
before update or delete on public.dv_accounting_deposit_receipt_issuances
for each row execute function public.dv_accounting_guard_approved_deposit_receipt();

drop trigger if exists trg_guard_approved_listing_trust_details on public.dv_accounting_transaction_trust;
create trigger trg_guard_approved_listing_trust_details
before update or delete on public.dv_accounting_transaction_trust
for each row execute function public.dv_accounting_guard_approved_deposit_receipt();

drop trigger if exists trg_guard_approved_trust_ledger on public.dv_accounting_trust_transactions;
create trigger trg_guard_approved_trust_ledger
before update or delete on public.dv_accounting_trust_transactions
for each row execute function public.dv_accounting_guard_approved_deposit_receipt();

drop policy if exists "lock approved listing deposit receipt files" on storage.objects;
create policy "lock approved listing deposit receipt files"
on storage.objects as restrictive for delete to authenticated
using (
  bucket_id <> 'dv-trade-documents'
  or (storage.foldername(name))[1] <> 'listings'
  or (storage.foldername(name))[3] <> 'listing-deposit-receipts'
  or public.dv_accounting_current_user_role() = 'SUPERADMIN'
  or not exists (
    select 1 from public.dv_accounting_deposit_receipt_issuances i
    join public.dv_accounting_trust_transactions t on t.id = i.trust_transaction_id
    where i.transaction_id = ((storage.foldername(name))[2])::uuid and i.approval_status = 'APPROVED'
  )
);

drop policy if exists "prevent updates to approved listing deposit receipt files" on storage.objects;
create policy "prevent updates to approved listing deposit receipt files"
on storage.objects as restrictive for update to authenticated
using (
  bucket_id <> 'dv-trade-documents'
  or (storage.foldername(name))[1] <> 'listings'
  or (storage.foldername(name))[3] <> 'listing-deposit-receipts'
  or public.dv_accounting_current_user_role() = 'SUPERADMIN'
  or not exists (
    select 1 from public.dv_accounting_deposit_receipt_issuances i
    join public.dv_accounting_trust_transactions t on t.id = i.trust_transaction_id
    where i.transaction_id = ((storage.foldername(name))[2])::uuid and i.approval_status = 'APPROVED'
  )
)
with check (
  bucket_id <> 'dv-trade-documents'
  or (storage.foldername(name))[1] <> 'listings'
  or (storage.foldername(name))[3] <> 'listing-deposit-receipts'
  or public.dv_accounting_current_user_role() = 'SUPERADMIN'
  or not exists (
    select 1 from public.dv_accounting_deposit_receipt_issuances i
    join public.dv_accounting_trust_transactions t on t.id = i.trust_transaction_id
    where i.transaction_id = ((storage.foldername(name))[2])::uuid and i.approval_status = 'APPROVED'
  )
);