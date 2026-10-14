-- 0066: return a transferred trade to review without deleting its accounting draft or archived details.
create or replace function public.dv_accounting_return_agent_trade_transfer(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  c record;
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
        raise exception 'This transfer cannot be returned because its accounting transaction is %. Only draft transfers can be returned here.', t.status;
      end if;

      if coalesce(t.ar_payment_received, false)
        or coalesce(t.ar_payment_amount, 0) > 0
        or coalesce(t.deposit_refunded, false) then
        raise exception 'This transfer has a recorded receipt or deposit refund. Reverse that financial activity before returning the trade.';
      end if;

      if exists (select 1 from public.dv_accounting_trust_transactions x where x.transaction_id = v_old_transaction_id)
        or exists (select 1 from public.dv_accounting_trust_liabilities x where x.transaction_id = v_old_transaction_id) then
        raise exception 'This transfer has trust ledger activity. Reverse the trust entries first to protect the trust records.';
      end if;

      -- Commission queue rows created for a draft transfer are retired from payroll,
      -- but remain in history. Any paid/posted/adjusted commission blocks the return.
      for c in
        select id, status, paid_date
        from public.dv_accounting_commissions
        where transaction_id = v_old_transaction_id
        for update
      loop
        if upper(coalesce(c.status, '')) = 'RETURNED' then
          continue;
        end if;
        if upper(coalesce(c.status, '')) <> 'READY' or c.paid_date is not null then
          raise exception 'This transfer has a commission that is no longer in the unused READY state. Return or reverse that commission through Commission Payroll first.';
        end if;
        if exists (select 1 from public.dv_accounting_commission_charges x where x.commission_id = c.id)
          or exists (select 1 from public.dv_accounting_commission_cheques x where x.commission_id = c.id)
          or exists (select 1 from public.dv_accounting_commission_corrections x where x.commission_id = c.id) then
          raise exception 'This transfer has linked commission charges, cheques, or corrections. Reverse those records first.';
        end if;
        update public.dv_accounting_commissions
        set status = 'RETURNED'
        where id = c.id;
      end loop;

      -- Keep the old draft and all accounting details/documents as a returned
      -- historical record. Hide it from normal operational transaction lists.
      update public.dv_accounting_transactions
      set status = 'RETURNED',
          commission_id = null,
          commission_approved = false,
          commission_approved_at = null,
          commission_approved_amount = null,
          commission_approved_agent_payable = null,
          commission_payroll_status = 'NOT_READY'
      where id = v_old_transaction_id;
    end if;

    -- Trade documents remain attached to the submission, ready for reapproval.
    update public.dv_accounting_agent_trade_documents
    set transaction_id = null
    where submission_id = s.id
      and transaction_id = v_old_transaction_id;
  end if;

  v_review_notes := concat_ws(E'\n',
    nullif(trim(coalesce(s.review_notes, '')), ''),
    'Transfer returned for editing by '
      || coalesce(auth.jwt()->>'email', 'administrator')
      || ' on ' || to_char(now(), 'YYYY-MM-DD HH24:MI')
      || '. The previous draft transfer and its records were retained as RETURNED history.'
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
