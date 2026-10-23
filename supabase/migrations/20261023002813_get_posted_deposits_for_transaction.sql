create or replace function public.dv_accounting_get_posted_deposits(p_transaction_id uuid)
returns setof public.dv_accounting_trust_transactions
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.dv_accounting_has_any_permission_all_scope(array['transactions.view'::text, 'banking.view'::text]) then
    raise exception 'You do not have permission to view trust deposits';
  end if;

  if not exists (
    select 1 from public.dv_accounting_transactions t
    where t.id = p_transaction_id
  ) then
    raise exception 'Transaction not found';
  end if;

  return query
  select d.*
  from public.dv_accounting_trust_transactions d
  where d.transaction_id = p_transaction_id
    and upper(coalesce(d.direction, '')) = 'DEPOSIT'
    and upper(coalesce(d.status, '')) = 'POSTED'
    and coalesce(d.amount, 0) > 0
  order by d.ledger_date desc nulls last, d.created_at desc;
end;
$$;

revoke all on function public.dv_accounting_get_posted_deposits(uuid) from public;
grant execute on function public.dv_accounting_get_posted_deposits(uuid) to authenticated;
notify pgrst, 'reload schema';
