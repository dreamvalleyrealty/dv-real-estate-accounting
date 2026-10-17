create or replace function public.dv_accounting_cancel_trade_change_request(p_submission_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only the Trade Admin Manager or an administrator can cancel a trade change request';
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status='SUBMITTED',
      review_notes=null,
      updated_at=now()
  where id=p_submission_id and status='NEEDS_CHANGES';

  if not found then
    raise exception 'Trade is not currently in Changes requested status';
  end if;
end;
$$;

revoke all on function public.dv_accounting_cancel_trade_change_request(uuid) from public, anon;
grant execute on function public.dv_accounting_cancel_trade_change_request(uuid) to authenticated;
