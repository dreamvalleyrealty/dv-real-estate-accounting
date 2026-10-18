-- Permanently keep listing deposits on the same accounting transaction when a
-- trade submission is approved, including submissions that already have a transaction
-- linked from a change-request workflow. Make receipt posting idempotent for retries.

do $migration$
declare
  v_definition text;
  v_updated text;
  v_anchor text := '  v_tx_id := s.transaction_id;';
  v_insert text := $patch$
  v_tx_id := s.transaction_id;

  -- The listing transaction is canonical. A submission may already have a separate
  -- draft transaction from a change-request workflow; prefer the listing-linked
  -- transaction so the original deposit receipt, trust ledger, and trade all share
  -- one transaction id. Resolve the listing id from the dedicated column first,
  -- then fall back to the historical payload field.
  if coalesce(nullif(trim(coalesce(p->>'listing_id','')), '')::uuid, s.listing_id) is not null then
    select * into t
    from public.dv_accounting_transactions x
    where x.listing_id = coalesce(nullif(trim(coalesce(p->>'listing_id','')), '')::uuid, s.listing_id)
    order by
      case when exists (
        select 1 from public.dv_accounting_trust_transactions d
        where d.transaction_id = x.id
          and d.direction = 'DEPOSIT'
          and d.trust_account_type = 'REAL_ESTATE_TRUST'
          and d.status = 'POSTED'
      ) then 0 else 1 end,
      x.created_at asc
    limit 1
    for update;

    if found and v_tx_id is distinct from t.id then
      v_tx_id := t.id;
      update public.dv_accounting_agent_trade_submissions
      set transaction_id = v_tx_id, updated_at = now()
      where id = s.id;
    end if;
  end if;
$patch$;
begin
  select pg_get_functiondef(p.oid)
    into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'dv_accounting_ensure_agent_trade_transaction'
    and pg_get_function_identity_arguments(p.oid) = 'p_submission_id uuid';

  if v_definition is null then
    raise exception 'Could not find dv_accounting_ensure_agent_trade_transaction(uuid)';
  end if;

  if position('The listing transaction is canonical.' in v_definition) > 0 then
    raise notice 'Canonical listing transaction reuse is already installed';
  else
    v_updated := replace(v_definition, v_anchor, v_insert);
    if v_updated = v_definition then
      raise exception 'Could not patch transaction ensure function: expected transaction-id anchor was not found';
    end if;
    execute v_updated;
  end if;
end;
$migration$;

-- A repeated receipt-posting request with the same transaction, account, date,
-- amount, and non-empty receipt reference returns the existing posting instead of
-- creating a second trust ledger entry, liability, or bank transaction.
do $migration$
declare
  v_definition text;
  v_updated text;
  v_anchor text := ' company:=coalesce(p_company_id,(select company_id from public.dv_accounting_bank_accounts where id=p_bank_account_id));';
  v_insert text := $patch$
 company:=coalesce(p_company_id,(select company_id from public.dv_accounting_bank_accounts where id=p_bank_account_id));

 if p_direction='DEPOSIT' and p_transaction_id is not null and nullif(trim(coalesce(p_reference,'')),'') is not null then
   select id into tt
   from public.dv_accounting_trust_transactions
   where transaction_id=p_transaction_id
     and bank_account_id=p_bank_account_id
     and ledger_date=coalesce(p_ledger_date,current_date)
     and trust_account_type=p_trust_account_type
     and direction='DEPOSIT'
     and status='POSTED'
     and amount=p_amount
     and reference=p_reference
   order by created_at asc
   limit 1
   for update;

   if found then
     select id into li
     from public.dv_accounting_trust_liabilities
     where trust_transaction_id=tt
     order by created_at asc
     limit 1;
     return jsonb_build_object('ok',true,'duplicate',true,'trust_transaction_id',tt,'liability_id',li);
   end if;
 end if;
$patch$;
begin
  select pg_get_functiondef(p.oid)
    into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'dv_accounting_post_trust_transaction'
    and pg_get_function_identity_arguments(p.oid) like 'p_company_id uuid, p_bank_account_id uuid, p_transaction_id uuid%';

  if v_definition is null then
    raise exception 'Could not find dv_accounting_post_trust_transaction';
  end if;

  if position('''duplicate'',true' in v_definition) > 0 then
    raise notice 'Idempotent trust deposit posting is already installed';
  else
    v_updated := replace(v_definition, v_anchor, v_insert);
    if v_updated = v_definition then
      raise exception 'Could not patch trust posting function: expected company assignment was not found';
    end if;
    execute v_updated;
  end if;
end;
$migration$;

-- Preserve the originating transaction on bank-side trust entries too. This makes
-- matching and reconciliation traceable without fuzzy address/amount comparisons.
alter table public.dv_accounting_bank_transactions
  add column if not exists transaction_id uuid references public.dv_accounting_transactions(id);
alter table public.dv_accounting_bank_transactions
  add column if not exists trust_transaction_id uuid references public.dv_accounting_trust_transactions(id) on delete set null;

create index if not exists dv_accounting_bank_transactions_trust_transaction_idx
  on public.dv_accounting_bank_transactions(trust_transaction_id);
create index if not exists dv_accounting_bank_transactions_transaction_idx
  on public.dv_accounting_bank_transactions(transaction_id);

-- Backfill historical bank entries only when the original receipt reference is an
-- exact match, avoiding guesses based on property address or amount alone.
update public.dv_accounting_bank_transactions bt
set transaction_id = tt.transaction_id,
    trust_transaction_id = tt.id
from public.dv_accounting_trust_transactions tt
where bt.trust_transaction_id is null
  and bt.transaction_id is null
  and bt.reference is not null
  and bt.reference = tt.reference
  and bt.bank_account_id = tt.bank_account_id
  and bt.transaction_date = tt.ledger_date
  and bt.amount = case when tt.direction = 'DEPOSIT' then tt.amount else -tt.amount end
  and tt.status = 'POSTED';

-- Keep every new bank-side entry tied to the trust posting that generated it.
do $migration$
declare
  v_definition text;
  v_updated text;
  v_anchor text := 'insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)';
  v_replacement text := 'insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference,transaction_id,trust_transaction_id)';
begin
  select pg_get_functiondef(p.oid)
    into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'dv_accounting_post_trust_transaction'
    and pg_get_function_identity_arguments(p.oid) like 'p_company_id uuid, p_bank_account_id uuid, p_transaction_id uuid%';

  if v_definition is null then
    raise exception 'Could not find dv_accounting_post_trust_transaction for bank-entry linkage';
  end if;

  if position('reference,transaction_id,trust_transaction_id)' in v_definition) = 0 then
    v_updated := replace(v_definition, v_anchor, v_replacement);
    if v_updated = v_definition then
      raise exception 'Could not patch trust posting function: bank transaction insert anchor was not found';
    end if;
    v_updated := replace(
      v_updated,
      ' values(p_bank_account_id,coalesce(p_ledger_date,current_date),p_description,',
      ' values(p_bank_account_id,coalesce(p_ledger_date,current_date),p_description,'
    );
    v_updated := replace(
      v_updated,
      '   case when p_direction = ''DEPOSIT'' then p_amount else -p_amount end,false,p_reference);',
      '   case when p_direction = ''DEPOSIT'' then p_amount else -p_amount end,false,p_reference,p_transaction_id,tt);'
    );
    v_updated := replace(
      v_updated,
      '   case when p_direction=''DEPOSIT'' then p_amount else -p_amount end,false,p_reference);',
      '   case when p_direction=''DEPOSIT'' then p_amount else -p_amount end,false,p_reference,p_transaction_id,tt);'
    );
    if v_updated = v_definition or position('p_reference,p_transaction_id,tt);' in v_updated) = 0 then
      raise exception 'Could not safely patch trust posting bank-entry values';
    end if;
    execute v_updated;
  end if;
end;
$migration$;
