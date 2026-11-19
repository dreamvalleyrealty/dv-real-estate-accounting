-- Allow Role & Permission grants to control agent personnel document access.
-- Existing management roles retain their current access.

drop policy if exists "personnel documents access" on public.dv_accounting_personnel_documents;

create policy "personnel documents view by role or permission"
on public.dv_accounting_personnel_documents
for select
to authenticated
using (
  public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
  or public.dv_accounting_has_permission_all_scope('agents.documents.view')
  or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
);

create policy "personnel documents insert by role or permission"
on public.dv_accounting_personnel_documents
for insert
to authenticated
with check (
  public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
  or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
);

create policy "personnel documents update by role or permission"
on public.dv_accounting_personnel_documents
for update
to authenticated
using (
  public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
  or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
)
with check (
  public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
  or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
);

-- Private personnel file access must follow the same grants as the document rows.
drop policy if exists "dv personnel read" on storage.objects;
drop policy if exists "dv personnel upload" on storage.objects;
drop policy if exists "dv personnel update" on storage.objects;

create policy "dv personnel read"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'dv-personnel'
  and (
    public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
    or public.dv_accounting_has_permission_all_scope('agents.documents.view')
    or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
  )
);

create policy "dv personnel upload"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'dv-personnel'
  and (
    public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
    or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
  )
);

create policy "dv personnel update"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'dv-personnel'
  and (
    public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
    or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
  )
)
with check (
  bucket_id = 'dv-personnel'
  and (
    public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
    or public.dv_accounting_has_permission_all_scope('agents.documents.manage')
  )
);
