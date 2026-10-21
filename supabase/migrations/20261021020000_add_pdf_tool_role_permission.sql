-- Add PDF Tool to the granular permission catalog and make it available by default.
-- Administrators can subsequently restrict access for any role or user in Role & Permission Control.
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
values ('pdf_splitter.view','PDF Tool','Access PDF Tool','Open PDF Splitter and PDF Merger to split, reorder, and combine PDF files.',220)
on conflict(code) do update
set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
values
 ('SUPERADMIN','pdf_splitter.view',true,'ALL'),
 ('ADMIN','pdf_splitter.view',true,'ALL'),
 ('MANAGER','pdf_splitter.view',true,'ALL'),
 ('STAFF','pdf_splitter.view',true,'ALL'),
 ('ACCOUNTANT','pdf_splitter.view',true,'ALL'),
 ('VIEWER','pdf_splitter.view',true,'ALL')
on conflict(role,permission_code) do update
set allowed=true,access_scope='ALL',updated_at=now();
