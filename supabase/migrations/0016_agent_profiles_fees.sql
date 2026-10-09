-- Agent master profile, memberships, bank details, fee plans and per-agent overrides

create table if not exists public.dv_accounting_real_estate_boards(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 province text not null default 'ON',
 active boolean not null default true,
 created_at timestamptz not null default now()
);

insert into public.dv_accounting_real_estate_boards(name,province) values
('Toronto Regional Real Estate Board','ON'),
('Mississauga Real Estate Board','ON'),
('Brampton Real Estate Board','ON'),
('Barrie & District Association of REALTORS®','ON'),
('Brantford Regional Real Estate Association','ON'),
('Central Lakes Association of REALTORS®','ON'),
('Chatham-Kent Association of REALTORS®','ON'),
('Cornerstone Association of REALTORS®','ON'),
('Cornwall and District Real Estate Board','ON'),
('Guelph & District Association of REALTORS®','ON'),
('Huron Perth Association of REALTORS®','ON'),
('Kawartha Lakes Real Estate Association','ON'),
('Kingston & Area Real Estate Association','ON'),
('Kitchener-Waterloo Association of REALTORS®','ON'),
('Lakelands Association of REALTORS®','ON'),
('London and St. Thomas Association of REALTORS®','ON'),
('Niagara Association of REALTORS®','ON'),
('North Bay Real Estate Board','ON'),
('Oakville, Milton & District Real Estate Board','ON'),
('OnePoint Association of REALTORS®','ON'),
('Ottawa Real Estate Board','ON'),
('Peterborough & the Kawarthas Association of REALTORS® Inc.','ON'),
('REALTORS® Association of Grey Bruce Owen Sound','ON'),
('REALTORS® Association of Hamilton-Burlington','ON'),
('Renfrew County Real Estate Board','ON'),
('Rideau–St. Lawrence Real Estate Board','ON'),
('Sarnia-Lambton Real Estate Board','ON'),
('Sault Ste. Marie Real Estate Board','ON'),
('Simcoe & District Real Estate Board','ON'),
('Sudbury Real Estate Board','ON'),
('Thunder Bay Real Estate Board','ON'),
('Timmins, Cochrane & Timiskaming Districts Association of REALTORS®','ON'),
('Windsor-Essex County Real Estate Board','ON'),
('Woodstock-Ingersoll & District Real Estate Board','ON'),
('Other / Custom','ON')
on conflict(name) do nothing;

alter table public.dv_accounting_agents
 add column if not exists agent_number text,
 add column if not exists first_name text,
 add column if not exists last_name text,
 add column if not exists legal_name text,
 add column if not exists incorporated boolean not null default false,
 add column if not exists corporation_name text,
 add column if not exists spouse_name text,
 add column if not exists address text,
 add column if not exists city text,
 add column if not exists province text default 'ON',
 add column if not exists postal_code text,
 add column if not exists cell_phone text,
 add column if not exists date_of_birth date,
 add column if not exists start_date date,
 add column if not exists anniversary_date date,
 add column if not exists termination_date date,
 add column if not exists incorporation_date date,
 add column if not exists reco_license_number text,
 add column if not exists reco_license_expiry date,
 add column if not exists hst_number text,
 add column if not exists prec_hst_number text;

create sequence if not exists public.dv_accounting_agent_number_seq start 1;

create or replace function public.dv_accounting_next_agent_number()
returns text language plpgsql as $$
declare n bigint;
begin
 n:=nextval('public.dv_accounting_agent_number_seq');
 return 'A-'||lpad(n::text,5,'0');
end $$;

alter table public.dv_accounting_agents alter column agent_number set default public.dv_accounting_next_agent_number();

update public.dv_accounting_agents
set agent_number=public.dv_accounting_next_agent_number()
where agent_number is null or agent_number='';

create unique index if not exists idx_dv_accounting_agents_agent_number on public.dv_accounting_agents(agent_number);

create table if not exists public.dv_accounting_agent_memberships(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 board_id uuid references public.dv_accounting_real_estate_boards(id),
 board_name text,
 membership_number text not null,
 created_at timestamptz not null default now()
);
create index if not exists idx_dv_accounting_agent_memberships_agent on public.dv_accounting_agent_memberships(agent_id);

create table if not exists public.dv_accounting_fee_plans(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
 name text not null,
 desk_fee numeric(14,2) not null default 0,
 admin_fee numeric(14,2) not null default 0,
 lead_fee numeric(14,2) not null default 0,
 commission_split_percent numeric(7,4) not null default 90,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name)
);

create table if not exists public.dv_accounting_agent_fee_settings(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 fee_plan_id uuid references public.dv_accounting_fee_plans(id),
 desk_fee_override numeric(14,2),
 admin_fee_override numeric(14,2),
 lead_fee_override numeric(14,2),
 commission_split_override_percent numeric(7,4),
 notes text,
 effective_date date,
 created_at timestamptz not null default now(),
 unique(agent_id)
);

create table if not exists public.dv_accounting_agent_bank_details(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 bank_name text,
 institution_number text,
 transit_number text,
 account_number text,
 account_type text check(account_type in ('CHEQUING','SAVINGS')),
 account_name text,
 created_at timestamptz not null default now(),
 unique(agent_id)
);

alter table public.dv_accounting_commissions
 add column if not exists commission_split_override_percent numeric(7,4),
 add column if not exists fee_adjustment numeric(14,2) not null default 0,
 add column if not exists adjustment_reason text;

do $$ declare t text; begin
 for t in select unnest(array[
 'dv_accounting_real_estate_boards','dv_accounting_agent_memberships','dv_accounting_fee_plans',
 'dv_accounting_agent_fee_settings','dv_accounting_agent_bank_details'
 ]) loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists "authenticated access" on public.%I',t);
  execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;
