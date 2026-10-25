create policy "additional agent trade submission read"
on public.dv_accounting_agent_trade_submissions
for select
to authenticated
using (
  payload ? 'associated_agent_ids'
  and payload->'associated_agent_ids' ? (public.dv_accounting_my_agent_id())::text
);
