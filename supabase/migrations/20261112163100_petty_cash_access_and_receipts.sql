insert into public.dv_accounting_petty_cash_settings(company_id,approval_threshold,receipt_threshold)
select id,100,25 from public.dv_accounting_companies on conflict(company_id) do nothing;
drop policy if exists petty_cash_settings_read on public.dv_accounting_petty_cash_settings;
create policy petty_cash_settings_read on public.dv_accounting_petty_cash_settings for select to authenticated using (
 company_id=(select up.company_id from public.dv_accounting_user_profiles up where up.user_id=auth.uid() and up.active=true)
 and (public.dv_accounting_current_user_role()='SUPERADMIN' or coalesce((public.dv_accounting_get_my_permissions()->'petty_cash.view'->>'allowed')::boolean,false))
);
drop policy if exists petty_cash_assigned_branch_read on public.dv_accounting_branches;
create policy petty_cash_assigned_branch_read on public.dv_accounting_branches for select to authenticated using (
 exists(select 1 from public.dv_accounting_petty_cash_funds f where f.branch_id=dv_accounting_branches.id and f.custodian_user_id=auth.uid())
 or public.dv_accounting_current_user_role()='SUPERADMIN'
 or public.dv_accounting_has_permission_all_scope('petty_cash.manage')
);
drop policy if exists petty_cash_category_read on public.dv_accounting_categories;
create policy petty_cash_category_read on public.dv_accounting_categories for select to authenticated using (
 category_type='EXPENSE' and (public.dv_accounting_current_user_role()='SUPERADMIN'
 or coalesce((public.dv_accounting_get_my_permissions()->'petty_cash.enter'->>'allowed')::boolean,false)
 or public.dv_accounting_has_permission_all_scope('petty_cash.view'))
);
drop policy if exists petty_cash_receipt_upload on storage.objects;
create policy petty_cash_receipt_upload on storage.objects for insert to authenticated with check (
 bucket_id='dv-vendor-invoices' and (storage.foldername(name))[1]='petty-cash'
 and (public.dv_accounting_current_user_role()='SUPERADMIN'
 or public.dv_accounting_has_permission_all_scope('petty_cash.enter')
 or exists(select 1 from public.dv_accounting_petty_cash_funds f where f.id=((storage.foldername(name))[2])::uuid and f.custodian_user_id=auth.uid() and f.active=true))
);
drop policy if exists petty_cash_receipt_read on storage.objects;
create policy petty_cash_receipt_read on storage.objects for select to authenticated using (
 bucket_id='dv-vendor-invoices' and (storage.foldername(name))[1]='petty-cash'
 and (public.dv_accounting_current_user_role()='SUPERADMIN'
 or public.dv_accounting_has_permission_all_scope('petty_cash.manage')
 or exists(select 1 from public.dv_accounting_petty_cash_funds f where f.id=((storage.foldername(name))[2])::uuid and (f.custodian_user_id=auth.uid() or public.dv_accounting_has_permission_all_scope('petty_cash.view'))))
);
revoke all on function public.dv_accounting_petty_cash_post_expense(uuid) from public,anon,authenticated;
revoke all on function public.dv_accounting_petty_cash_save_fund(uuid,numeric,uuid) from public,anon;
revoke all on function public.dv_accounting_petty_cash_save_settings(numeric,numeric) from public,anon;
revoke all on function public.dv_accounting_petty_cash_record_funding(uuid,numeric,text,uuid,text,date,text,text) from public,anon;
revoke all on function public.dv_accounting_petty_cash_submit_expense(uuid,date,text,text,text,numeric,numeric,text,text,text) from public,anon;
revoke all on function public.dv_accounting_petty_cash_review_expense(uuid,boolean,text,boolean) from public,anon;
grant execute on function public.dv_accounting_petty_cash_save_fund(uuid,numeric,uuid) to authenticated;
grant execute on function public.dv_accounting_petty_cash_save_settings(numeric,numeric) to authenticated;
grant execute on function public.dv_accounting_petty_cash_record_funding(uuid,numeric,text,uuid,text,date,text,text) to authenticated;
grant execute on function public.dv_accounting_petty_cash_submit_expense(uuid,date,text,text,text,numeric,numeric,text,text,text) to authenticated;
grant execute on function public.dv_accounting_petty_cash_review_expense(uuid,boolean,text,boolean) to authenticated;
