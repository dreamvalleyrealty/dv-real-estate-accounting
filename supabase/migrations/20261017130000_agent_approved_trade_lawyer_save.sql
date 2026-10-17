-- Allow an agent to update only lawyer fields on their already-approved trade.
-- Normal submission updates remain governed by the existing RLS policies.
create or replace function public.dv_accounting_agent_save_approved_trade_lawyer_details(
  p_submission_id uuid,
  p_lawyer_details jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_submission public.dv_accounting_agent_trade_submissions;
  v_lawyer_details jsonb;
begin
  select *
    into v_submission
    from public.dv_accounting_agent_trade_submissions
   where id = p_submission_id
   for update;

  if not found then
    raise exception 'Trade submission not found';
  end if;

  if v_submission.submitted_by is distinct from auth.uid() then
    raise exception 'You are not authorized to update lawyer details for this trade';
  end if;

  if v_submission.status <> 'APPROVED' then
    raise exception 'This function is only for approved trades';
  end if;

  select coalesce(jsonb_object_agg(item.key, item.value), '{}'::jsonb)
    into v_lawyer_details
    from jsonb_each(coalesce(p_lawyer_details, '{}'::jsonb)) as item
   where item.key = any (array[
     'seller_lawyer_name',
     'seller_lawyer_firm',
     'seller_lawyer_address',
     'seller_lawyer_phone',
     'seller_lawyer_fax',
     'seller_lawyer_email',
     'buyer_lawyer_name',
     'buyer_lawyer_firm',
     'buyer_lawyer_address',
     'buyer_lawyer_phone',
     'buyer_lawyer_fax',
     'buyer_lawyer_email'
   ]::text[]);

  update public.dv_accounting_agent_trade_submissions
     set payload = coalesce(payload, '{}'::jsonb) || v_lawyer_details,
         updated_at = now()
   where id = p_submission_id
   returning * into v_submission;

  return to_jsonb(v_submission);
end;
$$;

revoke all on function public.dv_accounting_agent_save_approved_trade_lawyer_details(uuid, jsonb) from public, anon;
grant execute on function public.dv_accounting_agent_save_approved_trade_lawyer_details(uuid, jsonb) to authenticated;
