create or replace function public.dv_accounting_admin_last_sign_ins()
returns table(user_id uuid, last_sign_in_at timestamptz)
language sql
security definer
set search_path = public, auth
stable
as $$
  select u.id, u.last_sign_in_at
  from auth.users u
  where exists (
    select 1
    from public.dv_accounting_user_profiles p
    where p.user_id = auth.uid()
      and upper(coalesce(p.role, '')) = 'SUPERADMIN'
      and coalesce(p.active, true) = true
  );
$$;

revoke all on function public.dv_accounting_admin_last_sign_ins() from public;
grant execute on function public.dv_accounting_admin_last_sign_ins() to authenticated;
