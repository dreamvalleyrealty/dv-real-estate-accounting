
ALTER TABLE public.dv_accounting_agents ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.dv_accounting_transactions ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.dv_accounting_expenses ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_created_by()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP='INSERT' THEN NEW.created_by:=auth.uid(); ELSE NEW.created_by:=OLD.created_by; END IF;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_dv_accounting_agents_created_by ON public.dv_accounting_agents;
CREATE TRIGGER trg_dv_accounting_agents_created_by BEFORE INSERT OR UPDATE ON public.dv_accounting_agents FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_set_created_by();
DROP TRIGGER IF EXISTS trg_dv_accounting_transactions_created_by ON public.dv_accounting_transactions;
CREATE TRIGGER trg_dv_accounting_transactions_created_by BEFORE INSERT OR UPDATE ON public.dv_accounting_transactions FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_set_created_by();
DROP TRIGGER IF EXISTS trg_dv_accounting_expenses_created_by ON public.dv_accounting_expenses;
CREATE TRIGGER trg_dv_accounting_expenses_created_by BEFORE INSERT OR UPDATE ON public.dv_accounting_expenses FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_set_created_by();

CREATE OR REPLACE FUNCTION public.dv_accounting_current_agent_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT a.id FROM public.dv_accounting_agents a
  WHERE lower(btrim(coalesce(a.email,'')))=lower(btrim(coalesce(auth.jwt()->>'email','')))
  ORDER BY a.created_at LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_current_employee_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.id FROM public.dv_accounting_employees e
  WHERE lower(btrim(coalesce(e.email,'')))=lower(btrim(coalesce(auth.jwt()->>'email','')))
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_current_branch_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT coalesce(
    (SELECT a.branch_id FROM public.dv_accounting_agents a WHERE lower(btrim(coalesce(a.email,'')))=lower(btrim(coalesce(auth.jwt()->>'email',''))) ORDER BY a.created_at LIMIT 1),
    (SELECT e.branch_id FROM public.dv_accounting_employees e WHERE lower(btrim(coalesce(e.email,'')))=lower(btrim(coalesce(auth.jwt()->>'email',''))) LIMIT 1)
  )
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_access_agent(p_agent_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text; target_branch uuid; current_agent uuid; current_branch uuid;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' THEN RETURN true; END IF;
  IF p_agent_id IS NULL THEN RETURN false; END IF;
  current_agent:=public.dv_accounting_current_agent_id();
  current_branch:=public.dv_accounting_current_branch_id();
  SELECT a.branch_id INTO target_branch FROM public.dv_accounting_agents a WHERE a.id=p_agent_id;
  IF sc='OWN' THEN
    RETURN p_agent_id=current_agent OR EXISTS(SELECT 1 FROM public.dv_accounting_agents a WHERE a.id=p_agent_id AND a.created_by=auth.uid());
  ELSIF sc='BRANCH' THEN
    RETURN current_branch IS NOT NULL AND target_branch=current_branch;
  END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_create_agent(p_email text,p_branch_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' OR sc='OWN' THEN RETURN true; END IF;
  IF sc='BRANCH' THEN RETURN p_branch_id IS NOT NULL AND p_branch_id=public.dv_accounting_current_branch_id(); END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_access_transaction(p_transaction_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text; tx public.dv_accounting_transactions%rowtype; current_agent uuid; current_branch uuid;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' THEN RETURN true; END IF;
  SELECT * INTO tx FROM public.dv_accounting_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RETURN false; END IF;
  current_agent:=public.dv_accounting_current_agent_id();
  current_branch:=public.dv_accounting_current_branch_id();
  IF sc='OWN' THEN
    RETURN tx.created_by=auth.uid() OR tx.agent_id=current_agent
      OR EXISTS(SELECT 1 FROM public.dv_accounting_transaction_agent_info ai WHERE ai.transaction_id=tx.id AND ai.agent_id=current_agent);
  ELSIF sc='BRANCH' THEN
    RETURN current_branch IS NOT NULL AND (
      EXISTS(SELECT 1 FROM public.dv_accounting_agents a WHERE a.id=tx.agent_id AND a.branch_id=current_branch)
      OR EXISTS(SELECT 1 FROM public.dv_accounting_transaction_agent_info ai JOIN public.dv_accounting_agents a ON a.id=ai.agent_id WHERE ai.transaction_id=tx.id AND a.branch_id=current_branch)
    );
  END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_create_transaction(p_agent_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' THEN RETURN true; END IF;
  IF sc='OWN' THEN RETURN public.dv_accounting_current_agent_id() IS NULL OR p_agent_id=public.dv_accounting_current_agent_id(); END IF;
  IF sc='BRANCH' THEN RETURN p_agent_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.dv_accounting_agents a WHERE a.id=p_agent_id AND a.branch_id=public.dv_accounting_current_branch_id()); END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_access_employee(p_employee_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text; target_branch uuid; current_employee uuid; current_branch uuid;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' THEN RETURN true; END IF;
  IF p_employee_id IS NULL THEN RETURN false; END IF;
  current_employee:=public.dv_accounting_current_employee_id();
  current_branch:=public.dv_accounting_current_branch_id();
  SELECT e.branch_id INTO target_branch FROM public.dv_accounting_employees e WHERE e.id=p_employee_id;
  IF sc='OWN' THEN RETURN p_employee_id=current_employee; END IF;
  IF sc='BRANCH' THEN RETURN current_branch IS NOT NULL AND target_branch=current_branch; END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_access_expense(p_expense_id uuid,p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text; owner_id uuid;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  IF sc='ALL' THEN RETURN true; END IF;
  IF sc='OWN' THEN SELECT e.created_by INTO owner_id FROM public.dv_accounting_expenses e WHERE e.id=p_expense_id; RETURN owner_id=auth.uid(); END IF;
  RETURN false;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_can_create_expense(p_permission_code text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p jsonb; sc text;
BEGIN
  IF public.dv_accounting_current_user_role()='SUPERADMIN' THEN RETURN true; END IF;
  p:=public.dv_accounting_get_my_permissions()->p_permission_code;
  IF coalesce((p->>'allowed')::boolean,false) IS NOT TRUE THEN RETURN false; END IF;
  sc:=coalesce(p->>'scope','OWN');
  RETURN sc IN ('ALL','OWN');
END
$function$;
