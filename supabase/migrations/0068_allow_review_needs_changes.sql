-- Allow Trade Admin to update review decisions for submissions that are already in NEEDS_CHANGES.
-- This supports reviewing the agent's corrected/resubmitted documents without a stale-state RPC error.
create or replace function public.dv_accounting_review_agent_trade_submission(
  p_submission_id uuid,
  p_status text,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dv_accounting_agent_trade_submissions%rowtype;
  v_tx_id uuid;
begin
  if not public.dv_accounting_is_trade_admin() then
    raise exception 'Only the Trade Admin Manager or an administrator can review submissions';
  end if;
  if p_status not in ('NEEDS_CHANGES','SUBMITTED') then
    raise exception 'Invalid review status';
  end if;

  select * into s
  from public.dv_accounting_agent_trade_submissions
  where id = p_submission_id
  for update;

  if not found or s.status not in ('SUBMITTED','NEEDS_CHANGES') then
    raise exception 'Submission not found or no longer awaiting review';
  end if;

  if p_status = 'NEEDS_CHANGES' then
    -- Ensure the linked accounting draft exists; the helper leaves non-draft transactions unchanged.
    v_tx_id := public.dv_accounting_ensure_agent_trade_transaction(s.id);
  end if;

  update public.dv_accounting_agent_trade_submissions
  set status = p_status,
      review_notes = nullif(trim(coalesce(p_notes,'')),''),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = s.id;
end;
$$;

revoke all on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) from public, anon;
grant execute on function public.dv_accounting_review_agent_trade_submission(uuid,text,text) to authenticated;
