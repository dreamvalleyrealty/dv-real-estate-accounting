-- Dedicated permission for managing agent direct-deposit information.
INSERT INTO public.dv_accounting_permission_catalog
  (code,module,label,description,sort_order,is_active)
VALUES
  ('agents.bank_details.manage','Agents','Manage agent direct deposit details',
   'View and update agent banking details, including institution, transit and account numbers, and upload or view direct-deposit forms and void cheques.',
   88,true)
ON CONFLICT (code) DO UPDATE SET
  module=EXCLUDED.module,label=EXCLUDED.label,description=EXCLUDED.description,
  sort_order=EXCLUDED.sort_order,is_active=true,updated_at=now();

-- Admin and Super Admin may manage agent banking details by default.
-- Other roles receive an explicit deny so access remains deliberate.
INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at)
VALUES
 ('SUPERADMIN','agents.bank_details.manage',true,'ALL',now()),
 ('ADMIN','agents.bank_details.manage',true,'ALL',now()),
 ('MANAGER','agents.bank_details.manage',false,'ALL',now()),
 ('STAFF','agents.bank_details.manage',false,'OWN',now()),
 ('ACCOUNTANT','agents.bank_details.manage',false,'ALL',now()),
 ('VIEWER','agents.bank_details.manage',false,'ALL',now()),
 ('AGENT','agents.bank_details.manage',false,'OWN',now())
ON CONFLICT (role,permission_code) DO UPDATE SET
 allowed=EXCLUDED.allowed,access_scope=EXCLUDED.access_scope,updated_at=now();

-- Agent bank details table: retain legacy Settings permission as a compatibility path.
DROP POLICY IF EXISTS dv_permission_select ON public.dv_accounting_agent_bank_details;
CREATE POLICY dv_permission_select ON public.dv_accounting_agent_bank_details
 FOR SELECT TO authenticated
 USING (public.dv_accounting_has_any_permission_all_scope(
   ARRAY['agents.bank_details.manage','settings.banking.manage','commission.issue']));

DROP POLICY IF EXISTS dv_permission_insert ON public.dv_accounting_agent_bank_details;
CREATE POLICY dv_permission_insert ON public.dv_accounting_agent_bank_details
 FOR INSERT TO authenticated
 WITH CHECK (public.dv_accounting_has_any_permission_all_scope(
   ARRAY['agents.bank_details.manage','settings.banking.manage']));

DROP POLICY IF EXISTS dv_permission_update ON public.dv_accounting_agent_bank_details;
CREATE POLICY dv_permission_update ON public.dv_accounting_agent_bank_details
 FOR UPDATE TO authenticated
 USING (public.dv_accounting_has_any_permission_all_scope(
   ARRAY['agents.bank_details.manage','settings.banking.manage']))
 WITH CHECK (public.dv_accounting_has_any_permission_all_scope(
   ARRAY['agents.bank_details.manage','settings.banking.manage']));

DROP POLICY IF EXISTS dv_permission_delete ON public.dv_accounting_agent_bank_details;
CREATE POLICY dv_permission_delete ON public.dv_accounting_agent_bank_details
 FOR DELETE TO authenticated
 USING (public.dv_accounting_has_any_permission_all_scope(
   ARRAY['agents.bank_details.manage','settings.banking.manage']));

-- Private personnel storage: use the dedicated Agents permission for direct-deposit
-- proof files. Preserve the existing rules for all other personnel documents.
DROP POLICY IF EXISTS "dv personnel read" ON storage.objects;
CREATE POLICY "dv personnel read" ON storage.objects
 FOR SELECT TO authenticated
 USING (
   bucket_id='dv-personnel' AND (
     (
       position('/direct-deposit/' in name)=0
       AND (
         public.dv_accounting_current_user_role()=ANY(ARRAY['SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT'])
         OR public.dv_accounting_has_permission_all_scope('agents.documents.view')
         OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
       )
     )
     OR (
       position('/direct-deposit/' in name)>0
       AND (
         public.dv_accounting_has_permission_all_scope('agents.bank_details.manage')
         OR public.dv_accounting_has_permission_all_scope('settings.banking.manage')
         OR split_part(name,'/',3)=public.dv_accounting_current_agent_id()::text
       )
     )
   )
 );

DROP POLICY IF EXISTS "dv personnel upload" ON storage.objects;
CREATE POLICY "dv personnel upload" ON storage.objects
 FOR INSERT TO authenticated
 WITH CHECK (
   bucket_id='dv-personnel' AND (
     (
       position('/direct-deposit/' in name)>0
       AND (
         public.dv_accounting_has_permission_all_scope('agents.bank_details.manage')
         OR public.dv_accounting_has_permission_all_scope('settings.banking.manage')
       )
     )
     OR (
       position('/direct-deposit/' in name)=0
       AND (
         public.dv_accounting_current_user_role()=ANY(ARRAY['SUPERADMIN','ADMIN','MANAGER'])
         OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
       )
     )
   )
 );

DROP POLICY IF EXISTS "dv personnel update" ON storage.objects;
CREATE POLICY "dv personnel update" ON storage.objects
 FOR UPDATE TO authenticated
 USING (
   bucket_id='dv-personnel' AND (
     (
       position('/direct-deposit/' in name)>0
       AND (
         public.dv_accounting_has_permission_all_scope('agents.bank_details.manage')
         OR public.dv_accounting_has_permission_all_scope('settings.banking.manage')
       )
     )
     OR (
       position('/direct-deposit/' in name)=0
       AND (
         public.dv_accounting_current_user_role()=ANY(ARRAY['SUPERADMIN','ADMIN','MANAGER'])
         OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
       )
     )
   )
 )
 WITH CHECK (
   bucket_id='dv-personnel' AND (
     (
       position('/direct-deposit/' in name)>0
       AND (
         public.dv_accounting_has_permission_all_scope('agents.bank_details.manage')
         OR public.dv_accounting_has_permission_all_scope('settings.banking.manage')
       )
     )
     OR (
       position('/direct-deposit/' in name)=0
       AND (
         public.dv_accounting_current_user_role()=ANY(ARRAY['SUPERADMIN','ADMIN','MANAGER'])
         OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
       )
     )
   )
 );

DROP POLICY IF EXISTS "dv personnel delete" ON storage.objects;
CREATE POLICY "dv personnel delete" ON storage.objects
 FOR DELETE TO authenticated
 USING (
   bucket_id='dv-personnel' AND (
     (
       position('/direct-deposit/' in name)>0
       AND (
         public.dv_accounting_has_permission_all_scope('agents.bank_details.manage')
         OR public.dv_accounting_has_permission_all_scope('settings.banking.manage')
       )
     )
     OR (
       position('/direct-deposit/' in name)=0
       AND public.dv_accounting_current_user_role()=ANY(ARRAY['SUPERADMIN','ADMIN'])
     )
   )
 );

NOTIFY pgrst,'reload schema';
