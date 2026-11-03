-- Secure banking instructions are stored separately from the day-to-day bank ledger.
-- Full account numbers are never exposed through authenticated table access.
create table if not exists public.dv_accounting_trust_account_instructions (
  account_type text primary key check (account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
  institution text not null,
  transit_number text not null,
  account_number_ciphertext bytea not null,
  account_name text not null,
  bank_address text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
alter table public.dv_accounting_trust_account_instructions enable row level security;
revoke all on public.dv_accounting_trust_account_instructions from anon, authenticated;

create table if not exists public.dv_accounting_trust_info_email_log (
  id uuid primary key default gen_random_uuid(),
  recipient_name text not null,
  recipient_email text not null,
  account_types text[] not null check (
    cardinality(account_types) between 1 and 2
    and account_types <@ array['REAL_ESTATE_TRUST','COMMISSION_TRUST']::text[]
  ),
  sent_by uuid not null references auth.users(id),
  sent_by_email text,
  status text not null default 'PENDING' check (
    status in ('PENDING','SENT','FAILED','VERIFIED','VIEWED','EXPIRED','REVOKED')
  ),
  token_hash text not null unique,
  otp_hash text,
  otp_expires_at timestamptz,
  otp_attempts integer not null default 0,
  link_expires_at timestamptz not null,
  verified_at timestamptz,
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error_message text,
  provider_message_id text
);
create index if not exists dv_accounting_trust_info_email_log_expiry_idx
 on public.dv_accounting_trust_info_email_log(link_expires_at);
create index if not exists dv_accounting_trust_info_email_log_sender_idx
 on public.dv_accounting_trust_info_email_log(sent_by,created_at desc);
alter table public.dv_accounting_trust_info_email_log enable row level security;
revoke all on public.dv_accounting_trust_info_email_log from anon;
revoke all on public.dv_accounting_trust_info_email_log from authenticated;
grant select on public.dv_accounting_trust_info_email_log to authenticated;
drop policy if exists "Trust information history sender or admin" on public.dv_accounting_trust_info_email_log;
create policy "Trust information history sender or admin"
 on public.dv_accounting_trust_info_email_log
 for select to authenticated
 using (
   sent_by = auth.uid()
   or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
 );

create or replace function public.dv_accounting_store_trust_account_instruction(
 p_account_type text,
 p_institution text,
 p_transit_number text,
 p_account_number_ciphertext bytea,
 p_account_name text,
 p_bank_address text default null
) returns void
language plpgsql security definer set search_path=public
as $$
begin
 if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN') then
   raise exception 'Only an administrator can update trust banking instructions';
 end if;
 if p_account_type not in ('REAL_ESTATE_TRUST','COMMISSION_TRUST') then
   raise exception 'Invalid trust account type';
 end if;
 if length(coalesce(p_institution,''))=0 or length(coalesce(p_transit_number,''))=0
   or length(coalesce(p_account_name,''))=0 or p_account_number_ciphertext is null
   or octet_length(p_account_number_ciphertext)=0 then
   raise exception 'Complete all required banking fields';
 end if;
 insert into public.dv_accounting_trust_account_instructions(
   account_type,institution,transit_number,account_number_ciphertext,account_name,bank_address,updated_at,updated_by
 ) values(p_account_type,p_institution,p_transit_number,p_account_number_ciphertext,p_account_name,p_bank_address,now(),auth.uid())
 on conflict(account_type) do update set
   institution=excluded.institution,transit_number=excluded.transit_number,
   account_number_ciphertext=excluded.account_number_ciphertext,account_name=excluded.account_name,
   bank_address=excluded.bank_address,updated_at=now(),updated_by=auth.uid();
end $$;
revoke all on function public.dv_accounting_store_trust_account_instruction(text,text,text,bytea,text,text) from public,anon,authenticated;
grant execute on function public.dv_accounting_store_trust_account_instruction(text,text,text,bytea,text,text) to service_role;
