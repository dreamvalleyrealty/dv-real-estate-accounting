-- 0065: safely return an approved trade to review and remove only its unused draft transaction.
create or replace function public.dv_accounting_return_agent_trade_transfer(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  v_ref record;
  v_has_reference boolean;
  v_old_transaction_id uuid;
  v_review_notes text;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only a trade administrator can return an approved transfer';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then
    raise exception 'Trade submission not found';
  end if;
  if s.status <> 'APPROVED' then
    raise exception 'Only an approved trade can have its transfer returned';
  end if;

  v_old_transaction_id := s.transaction_id;

  if v_old_transaction_id is not null then
    select * into t
    from public.dv_accounting_transactions
    where id = v_old_transaction_id
    for update;

    if found then
      if upper(coalesce(t.status, 'DRAFT')) <> 'DRAFT' then
        raise exception 'This transfer cannot be returned because its accounting transaction is %. Return or reopen it through the accounting workflow first.', t.status;
      end if;

      -- Protect any transaction that has dependent data beyond the people copied
      -- from the submission. Documents attached to the trade submission itself
      -- are retained and unlinked below.
      for v_ref in
        select distinct ns.nspname as schema_name, rel.relname as table_name, att.attname as column_name
        from pg_constraint con
        join pg_class rel on rel.oid = con.conrelid
        join pg_namespace ns on ns.oid = rel.relnamespace
        join lateral unnest(con.conkey) as fk(attnum) on true
        join pg_attribute att on att.attrelid = rel.oid and att.attnum = fk.attnum
        where con.contype = 'f'
          and con.confrelid = 'public.dv_accounting_transactions'::regclass
          and not (
            ns.nspname = 'public'
            and rel.relname in (
              'dv_accounting_agent_trade_submissions',
              'dv_accounting_agent_trade_documents',
              'dv_accounting_transaction_people'
            )
          )
      loop
        execute format('select exists (select 1 from %I.%I where %I = $1)',
          v_ref.schema_name, v_ref.table_name, v_ref.column_name)
          into v_has_reference using v_old_transaction_id;
        if v_has_reference then
          raise exception 'Cannot return this transfer because linked records exist in %.%. Reverse those records first to protect accounting history.',
            v_ref.schema_name, v_ref.table_name;
        end if;
      end loop;

      -- Also check UUID transaction_id columns that are not protected by a
      -- declared foreign key, so legacy financial tables are not overlooked.
      for v_ref in
        select table_schema as schema_name, table_name
        from information_schema.columns
        where table_schema = 'public'
          and column_name = 'transaction_id'
          and udt_name = 'uuid'
          and table_name not in (
            'dv_accounting_agent_trade_submissions',
            'dv_accounting_agent_trade_documents',
            'dv_accounting_transaction_people'
          )
      loop
        execute format('select exists (select 1 from %I.%I where transaction_id = $1)',
          v_ref.schema_name, v_ref.table_name)
          into v_has_reference using v_old_transaction_id;
        if v_has_reference then
          raise exception 'Cannot return this transfer because linked records exist in %.%. Reverse those records first to protect accounting history.',
            v_ref.schema_name, v_ref.table_name;
        end if;
      end loop;

      -- Keep the submitted trade documents; they remain attached to the trade
      -- submission and can be carried to the replacement transaction on approval.
      update public.dv_accounting_agent_trade_documents
      set transaction_id = null
      where submission_id = s.id
        and transaction_id = v_old_transaction_id;

      delete from public.dv_accounting_transactions
      where id = v_old_transaction_id;
      if not found then
        raise exception 'The linked draft transaction could not be removed; no transfer changes were completed';
      end if;
    end if;
  end if;

  v_review_notes := concat_ws(E'\n',
    nullif(trim(coalesce(s.review_notes, '')), ''),
    'Transfer returned for editing by '
      || coalesce(auth.jwt()->>'email', 'administrator')
      || ' on ' || to_char(now(), 'YYYY-MM-DD HH24:MI')
      || '. The trade is unapproved and back in the review queue.'
  );

  update public.dv_accounting_agent_trade_submissions
  set status = 'SUBMITTED',
      transaction_id = null,
      review_notes = v_review_notes,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = s.id;

  return jsonb_build_object(
    'submission_id', s.id,
    'status', 'SUBMITTED',
    'transaction_id', null,
    'returned_transaction_id', v_old_transaction_id,
    'review_notes', v_review_notes
  );
end;
$$;

revoke all on function public.dv_accounting_return_agent_trade_transfer(uuid) from public, anon;
grant execute on function public.dv_accounting_return_agent_trade_transfer(uuid) to authenticated;
