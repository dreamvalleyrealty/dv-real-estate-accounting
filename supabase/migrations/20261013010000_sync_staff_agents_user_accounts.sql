-- Connect payroll staff, agents, and authentication accounts through stable user IDs.
ALTER TABLE public.dv_accounting_agents
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.dv_accounting_employees
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS dv_accounting_agents_user_id_uidx
  ON public.dv_accounting_agents(user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS dv_accounting_employees_user_id_uidx
  ON public.dv_accounting_employees(user_id) WHERE user_id IS NOT NULL;

-- Link existing records to matching login accounts by email, only when the email maps to one record.
WITH matches AS (
  SELECT a.id, u.id AS user_id,
         row_number() OVER (PARTITION BY lower(btrim(a.email)) ORDER BY a.created_at NULLS LAST, a.id) AS rn
  FROM public.dv_accounting_agents a
  JOIN auth.users u ON lower(btrim(a.email))=lower(btrim(u.email))
  WHERE nullif(btrim(a.email),'') IS NOT NULL AND a.user_id IS NULL
)
UPDATE public.dv_accounting_agents a SET user_id=m.user_id
FROM matches m WHERE m.id=a.id AND m.rn=1
  AND (SELECT count(*) FROM public.dv_accounting_agents a2 WHERE lower(btrim(a2.email))=lower(btrim(a.email)))=1;

WITH matches AS (
  SELECT e.id, u.id AS user_id,
         row_number() OVER (PARTITION BY lower(btrim(e.email)) ORDER BY e.id) AS rn
  FROM public.dv_accounting_employees e
  JOIN auth.users u ON lower(btrim(e.email))=lower(btrim(u.email))
  WHERE nullif(btrim(e.email),'') IS NOT NULL AND e.user_id IS NULL
)
UPDATE public.dv_accounting_employees e SET user_id=m.user_id
FROM matches m WHERE m.id=e.id AND m.rn=1
  AND (SELECT count(*) FROM public.dv_accounting_employees e2 WHERE lower(btrim(e2.email))=lower(btrim(e.email)))=1;

-- Ensure every existing linked login has a profile row without changing an existing role or permission setup.
INSERT INTO public.dv_accounting_user_profiles(user_id,display_name,email,role,active)
SELECT u.id,
       coalesce(nullif(btrim(u.raw_user_meta_data->>'display_name'),''),nullif(btrim(u.raw_user_meta_data->>'full_name'),''),split_part(u.email,'@',1)),
       u.email,
       CASE lower(coalesce(u.raw_app_meta_data->>'role','staff'))
         WHEN 'superadmin' THEN 'SUPERADMIN' WHEN 'super_admin' THEN 'SUPERADMIN'
         WHEN 'admin' THEN 'ADMIN' WHEN 'manager' THEN 'MANAGER'
         WHEN 'accountant' THEN 'ACCOUNTANT' WHEN 'viewer' THEN 'VIEWER'
         WHEN 'agent' THEN 'AGENT' ELSE 'STAFF'
       END,
       true
FROM auth.users u
WHERE EXISTS (SELECT 1 FROM public.dv_accounting_agents a WHERE a.user_id=u.id)
   OR EXISTS (SELECT 1 FROM public.dv_accounting_employees e WHERE e.user_id=u.id)
ON CONFLICT(user_id) DO NOTHING;
