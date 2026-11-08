revoke all on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) from public, anon;
grant execute on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) to authenticated;

revoke all on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) from public, anon;
grant execute on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) to authenticated;

revoke all on function public.dv_accounting_validate_buyer_rebate_trade() from public, anon, authenticated;
