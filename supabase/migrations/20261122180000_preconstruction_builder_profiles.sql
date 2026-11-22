-- Reusable builder profiles and transaction-level snapshots for pre-construction commission terms.
create table if not exists public.dv_accounting_preconstruction_builder_profiles (
 id uuid primary key default gen_random_uuid(),
 builder_name text not null,
 billing_email text,
 billing_phone text,
 billing_address text,
 billing_city text,
 billing_province text default 'ON',
 billing_postal_code text,
 calculation_method text not null default 'PERCENT_PURCHASE_PRICE'
   check (calculation_method in ('PERCENT_PURCHASE_PRICE','PERCENT_NET_OF_EXTRAS','FIXED_AMOUNT','TIERED')),
 commission_rate numeric(10,4) not null default 0,
 fixed_commission_amount numeric(14,2),
 calculation_basis text not null default 'PURCHASE_PRICE_EXCLUSIVE_OF_HST',
 excluded_items text[] not null default '{}',
 hst_applicable boolean not null default true,
 hst_rate numeric(6,3) not null default 13,
 earned_trigger text not null default 'CLOSING_COMPLETED',
 payment_due_days integer not null default 30,
 payment_terms text,
 termination_terms text,
 required_documents text[] not null default '{}',
 notes text,
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.dv_accounting_transactions
 add column if not exists commission_payer_profile_id uuid references public.dv_accounting_preconstruction_builder_profiles(id) on delete set null,
 add column if not exists preconstruction_commission_terms jsonb not null default '{}'::jsonb,
 add column if not exists preconstruction_project_name text,
 add column if not exists preconstruction_unit_block text,
 add column if not exists preconstruction_purchaser_names text;
alter table public.dv_accounting_preconstruction_builder_profiles enable row level security;
drop policy if exists "Authenticated users can read active preconstruction builder profiles" on public.dv_accounting_preconstruction_builder_profiles;
create policy "Authenticated users can read active preconstruction builder profiles"
 on public.dv_accounting_preconstruction_builder_profiles for select to authenticated
 using (is_active or public.dv_accounting_has_permission('settings.view'));
drop policy if exists "Authorized admins manage preconstruction builder profiles" on public.dv_accounting_preconstruction_builder_profiles;
create policy "Authorized admins manage preconstruction builder profiles"
 on public.dv_accounting_preconstruction_builder_profiles for all to authenticated
 using (public.dv_accounting_has_permission('settings.view'))
 with check (public.dv_accounting_has_permission('settings.view'));
create index if not exists dv_accounting_preconstruction_builder_profiles_name_idx
 on public.dv_accounting_preconstruction_builder_profiles (lower(builder_name));
insert into public.dv_accounting_preconstruction_builder_profiles
 (builder_name,billing_address,billing_city,billing_province,billing_postal_code,
  calculation_method,commission_rate,calculation_basis,excluded_items,hst_applicable,hst_rate,
  earned_trigger,payment_due_days,payment_terms,termination_terms,required_documents,notes)
select 'Zancor Homes (Caledon) Ltd.','221 North Rivermede','Concord','ON','L4K 3N7',
 'PERCENT_NET_OF_EXTRAS',3,'PURCHASE_PRICE_EXCLUSIVE_OF_HST',
 array['Extras','Lot premiums','Walk-out basements','Finished basements','Options added after APS date'],
 true,13,'CLOSING_COMPLETED',30,
 'Payment is due 30 days after closing.',
 'No commission is earned unless the transaction closes. If the agreement is terminated, no commission is earned and any commission already paid must be refunded in accordance with the agreement.',
 array['Commission invoice','Signed Agreement to Co-operate','Confirmation of Co-operation','Representation Agreement (if required by builder)'],
 'Initial profile based on the Zancor Homes (Caledon) Ltd. Agreement to Co-operate supplied for The Social – Urban Towns at Caledon Club.'
where not exists (select 1 from public.dv_accounting_preconstruction_builder_profiles where lower(builder_name)=lower('Zancor Homes (Caledon) Ltd.'));
