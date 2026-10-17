create or replace function public.dv_accounting_cancel_agent_trade_review(p_submission_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
begin
  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found then
    raise exception 'Trade submission not found';
  end if;

  if not public.dv_accounting_is_trade_admin()
     and s.submitted_by is distinct from auth.uid() then
    raise exception 'Only the submitting agent or an administrator can cancel this review';
  end if;

  if s.status <> 'SUBMITTED' then
    raise exception 'Only a trade awaiting review can be cancelled';
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status = 'DRAFT',
      submitted_at = null,
      updated_at = now()
  where id = s.id;
end;
$function$;

revoke all on function public.dv_accounting_cancel_agent_trade_review(uuid) from public, anon;
grant execute on function public.dv_accounting_cancel_agent_trade_review(uuid) to authenticated;
notify pgrst, 'reload schema';
