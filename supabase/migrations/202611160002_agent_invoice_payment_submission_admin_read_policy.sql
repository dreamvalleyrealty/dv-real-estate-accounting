grant select on public.dv_agent_invoice_payment_submissions to authenticated;
drop policy if exists "management can view invoice payment submissions" on public.dv_agent_invoice_payment_submissions;
create policy "management can view invoice payment submissions"
on public.dv_agent_invoice_payment_submissions
for select to authenticated
using (public.dv_is_management_user());