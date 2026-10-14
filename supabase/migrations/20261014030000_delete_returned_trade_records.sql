-- Permanently remove only returned transactions and pending submissions,
-- with strict guards around posted/reconciled/paid accounting activity.
create or replace function public.dv_accounting_delete_trade_record(
  p_transaction_id uuid default null,
  p_submission_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  v_tx_id uuid;
  v_tx_no text;
  v_submission_ids uuid[] := array[]::uuid[];
  v_deleted_submission_ids uuid[] := array[]::uuid[];
begin
  if coalesce(public.dv_accounting_current_user_role(), '') <> 'SUPERADMIN' then
    raise exception 'Only Super Admin can permanently delete a returned transaction or trade submission';
  end if;

  if (p_transaction_id is null) = (p_submission_id is null) then
    raise exception 'Provide exactly one transaction ID or submission ID';
  end if;

  if p_submission_id is not null then
    select * into s
    from public.dv_accounting_agent_trade_submissions
    where id = p_submission_id
    for update;

    if not found then raise exception 'Trade submission not found'; end if;
    if upper(coalesce(s.status, '')) not in ('DRAFT','SUBMITTED','NEEDS_CHANGES') then
      raise exception 'Only draft, awaiting-review, or changes-requested submissions can be deleted';
    end if;

    v_tx_id := s.transaction_id;
    v_submission_ids := array[s.id];

    if v_tx_id is not null then
      select * into t
      from public.dv_accounting_transactions
      where id = v_tx_id
      for update;
      if not found then raise exception 'The linked transaction could not be found'; end if;
      if upper(coalesce(t.status,'')) <> 'RETURNED' then
        raise exception 'This submission is linked to an active transaction. Only a RETURNED transaction can be deleted with its submission.';
      end if;
    end if;
  else
    v_tx_id := p_transaction_id;
    select * into t
    from public.dv_accounting_transactions
    where id = v_tx_id
    for update;

    if not found then raise exception 'Transaction not found'; end if;
    if upper(coalesce(t.status,'')) <> 'RETURNED' then
      raise exception 'This delete action is only available for transactions marked RETURNED';
    end if;

    if exists (
      select 1 from public.dv_accounting_agent_trade_submissions s0
      where s0.transaction_id = v_tx_id
        and upper(coalesce(s0.status,'')) not in ('DRAFT','SUBMITTED','NEEDS_CHANGES')
    ) then
      raise exception 'A linked submission is not in a deletable pending state';
    end if;

    select coalesce(array_agg(s0.id), array[]::uuid[]) into v_submission_ids
    from public.dv_accounting_agent_trade_submissions s0
    where s0.transaction_id = v_tx_id;
  end if;

  if v_tx_id is not null then
    v_tx_no := t.transaction_number;

    if coalesce(t.ar_payment_received,false)
      or coalesce(t.ar_payment_amount,0) > 0
      or coalesce(t.deposit_refunded,false)
      or upper(coalesce(t.commission_payroll_status,'NOT_READY')) = 'PAID' then
      raise exception 'Cannot delete this transaction because a receipt, deposit refund, or paid commission is recorded';
    end if;

    if exists (select 1 from public.dv_accounting_trust_transactions x where x.transaction_id=v_tx_id)
      or exists (select 1 from public.dv_accounting_trust_liabilities x where x.transaction_id=v_tx_id) then
      raise exception 'Trust-account receipts or liabilities are still linked. Reverse or remove test trust activity through the trust workflow before deleting this transaction.';
    end if;

    if exists (select 1 from public.dv_trust_transactions x where x.deal_id=v_tx_id)
      or exists (select 1 from public.dv_trust_ledger x where x.deal_id=v_tx_id or x.transaction_id=v_tx_id)
      or exists (select 1 from public.dv_trust_cheques x where x.deal_id=v_tx_id) then
      raise exception 'Legacy trust ledger, trust cheque, or trust transaction activity is linked. Resolve it through the trust workflow before deleting.';
    end if;

    if exists (select 1 from public.dv_accounting_journal_entries x where x.source_id=v_tx_id)
      or exists (select 1 from public.dv_journal_entries x where x.source_record_id=v_tx_id)
      or exists (select 1 from public.dv_journal_lines x where x.deal_id=v_tx_id)
      or exists (select 1 from public.dv_accounting_events x where x.source_record_id=v_tx_id or x.deal_id=v_tx_id) then
      raise exception 'Accounting journal/event records are linked. Reverse those records through accounting before deleting this transaction.';
    end if;

    if exists (
      select 1 from public.dv_accounting_bank_transactions b
      where b.reconciled is true
        and (b.description = 'Deposit received for trade ' || coalesce(v_tx_no,'')
          or b.reference in (select nullif(trim(tt.reference_number),'') from public.dv_accounting_transaction_trust tt where tt.transaction_id=v_tx_id))
    ) then
      raise exception 'A matching bank transaction is reconciled. Do not delete it; use the accounting correction workflow.';
    end if;

    if exists (select 1 from public.dv_accounting_commission_charges c where c.transaction_id=v_tx_id)
      or exists (select 1 from public.dv_accounting_commission_corrections c where c.transaction_id=v_tx_id)
      or exists (
        select 1 from public.dv_accounting_commissions c
        where c.transaction_id=v_tx_id
          and (upper(coalesce(c.status,'')) not in ('READY','RETURNED') or c.paid_date is not null)
      )
      or exists (
        select 1 from public.dv_accounting_commission_cheques q
        where q.commission_id in (select c.id from public.dv_accounting_commissions c where c.transaction_id=v_tx_id)
      )
      or exists (
        select 1 from public.dv_accounting_commission_charges q
        where q.commission_id in (select c.id from public.dv_accounting_commissions c where c.transaction_id=v_tx_id)
      )
      or exists (
        select 1 from public.dv_accounting_commission_corrections q
        where q.commission_id in (select c.id from public.dv_accounting_commissions c where c.transaction_id=v_tx_id)
      ) then
      raise exception 'Commission charges, cheques, corrections, or paid commission records are linked. Resolve those records first.';
    end if;

    if exists (
      select 1 from public.dv_accounting_seller_settlements ss
      where ss.transaction_id=v_tx_id and (
        ss.commission_payroll_id is not null
        or ss.payments_completed_at is not null
        or coalesce(ss.listing_agent_paid_amount,0)>0
        or coalesce(ss.cooperating_brokerage_paid_amount,0)>0
        or (coalesce(ss.seller_paid_amount,0)>0 and coalesce(ss.seller_payment_reference,'') not ilike 'TEST%')
      )
    ) then
      raise exception 'Seller settlement or commission payments appear completed. Resolve that settlement before deleting this transaction.';
    end if;

    delete from public.dv_accounting_bank_transactions b
    where b.reconciled is false
      and (b.description = 'Deposit received for trade ' || coalesce(v_tx_no,'')
        or b.reference in (select nullif(trim(tt.reference_number),'') from public.dv_accounting_transaction_trust tt where tt.transaction_id=v_tx_id));

    delete from public.dv_accounting_seller_settlements where transaction_id=v_tx_id;
    delete from public.dv_accounting_agent_trade_documents where transaction_id=v_tx_id or submission_id=any(v_submission_ids);
    delete from public.dv_accounting_transaction_documents where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_file_requirements where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_deposits where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_trust where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_agent_info where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_agents where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_commissions where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_outside_brokers where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_conditions where transaction_id=v_tx_id;
    delete from public.dv_accounting_transaction_people where transaction_id=v_tx_id;
    delete from public.dv_accounting_commissions where transaction_id=v_tx_id;

    delete from public.dv_accounting_agent_trade_submissions where transaction_id=v_tx_id and id=any(v_submission_ids) returning id into s.id;
    -- Also remove the requested pending submission if it was identified independently.
    if p_submission_id is not null then
      delete from public.dv_accounting_agent_trade_submissions where id=p_submission_id;
      v_deleted_submission_ids := array[p_submission_id];
    else
      v_deleted_submission_ids := v_submission_ids;
    end if;

    delete from public.dv_accounting_transactions where id=v_tx_id;
  else
    delete from public.dv_accounting_agent_trade_documents where submission_id=p_submission_id;
    delete from public.dv_accounting_agent_trade_submissions where id=p_submission_id;
    v_deleted_submission_ids := array[p_submission_id];
  end if;

  return jsonb_build_object(
    'deleted', true,
    'transaction_id', v_tx_id,
    'submission_ids', to_jsonb(v_deleted_submission_ids),
    'transaction_number', v_tx_no
  );
end;
$$;

revoke all on function public.dv_accounting_delete_trade_record(uuid,uuid) from public, anon;
grant execute on function public.dv_accounting_delete_trade_record(uuid,uuid) to authenticated;