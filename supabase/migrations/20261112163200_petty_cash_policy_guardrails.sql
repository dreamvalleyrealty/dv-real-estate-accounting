-- Guardrails for threshold defaults and rejection workflow.
create or replace function public.dv_accounting_petty_cash_submit_expense(p_fund_id uuid,p_transaction_date date,p_vendor text,p_category text,p_description text,p_amount numeric,p_hst_amount numeric,p_receipt_storage_path text default null,p_receipt_file_name text default null,p_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f public.dv_accounting_petty_cash_funds%rowtype; v_company uuid; v_perm jsonb; v_approval numeric(14,2):=100; v_receipt numeric(14,2):=25; v_total numeric(14,2); v_status text; tx uuid; result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into f from public.dv_accounting_petty_cash_funds where id=p_fund_id and active=true;
 if not found then raise exception 'Active petty cash fund not found'; end if;
 select company_id into v_company from public.dv_accounting_user_profiles where user_id=auth.uid() and active=true;
 if v_company is distinct from f.company_id then raise exception 'Fund belongs to a different company'; end if;
 v_perm:=public.dv_accounting_get_my_permissions()->'petty_cash.enter';
 if not (f.custodian_user_id=auth.uid() and coalesce((v_perm->>'allowed')::boolean,false)) and not public.dv_accounting_has_permission_all_scope('petty_cash.enter') then raise exception 'You are not assigned to this branch petty cash fund'; end if;
 select coalesce(approval_threshold,100),coalesce(receipt_threshold,25) into v_approval,v_receipt from public.dv_accounting_petty_cash_settings where company_id=f.company_id;
 v_approval:=coalesce(v_approval,100); v_receipt:=coalesce(v_receipt,25); v_total:=round(coalesce(p_amount,0)+coalesce(p_hst_amount,0),2);
 if nullif(trim(coalesce(p_vendor,'')),'') is null or nullif(trim(coalesce(p_category,'')),'') is null or nullif(trim(coalesce(p_description,'')),'') is null then raise exception 'Vendor, category and description are required'; end if;
 if coalesce(p_amount,0)<=0 or coalesce(p_hst_amount,0)<0 then raise exception 'Enter valid expense and HST amounts'; end if;
 if v_total>v_receipt and nullif(trim(coalesce(p_receipt_storage_path,'')),'') is null then raise exception 'A receipt is required for expenses above $%',v_receipt; end if;
 v_status:=case when v_total>v_approval then 'PENDING' else 'APPROVED' end;
 insert into public.dv_accounting_petty_cash_transactions(company_id,fund_id,transaction_type,transaction_date,amount,hst_amount,vendor,category,description,receipt_storage_path,receipt_file_name,reference,approval_status,approved_by,approved_at,created_by)
 values(f.company_id,f.id,'EXPENSE',coalesce(p_transaction_date,current_date),round(p_amount,2),round(p_hst_amount,2),trim(p_vendor),trim(p_category),trim(p_description),nullif(trim(p_receipt_storage_path),''),nullif(trim(p_receipt_file_name),''),nullif(trim(p_reference),''),v_status,case when v_status='APPROVED' then auth.uid() else null end,case when v_status='APPROVED' then now() else null end,auth.uid()) returning id into tx;
 if v_status='APPROVED' then result:=public.dv_accounting_petty_cash_post_expense(tx); return result||jsonb_build_object('transaction_id',tx,'approval_status','APPROVED'); end if;
 return jsonb_build_object('transaction_id',tx,'approval_status','PENDING','total_amount',v_total);
end $$;
create or replace function public.dv_accounting_petty_cash_review_expense(p_transaction_id uuid,p_approve boolean,p_note text default null,p_cash_returned boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.dv_accounting_petty_cash_transactions%rowtype; result jsonb;
begin
 if auth.uid() is null or not (public.dv_accounting_current_user_role()='SUPERADMIN' or public.dv_accounting_has_permission_all_scope('petty_cash.approve')) then raise exception 'You do not have permission to review petty cash expenses'; end if;
 select * into t from public.dv_accounting_petty_cash_transactions where id=p_transaction_id for update;
 if not found or t.transaction_type<>'EXPENSE' or t.approval_status<>'PENDING' then raise exception 'Pending petty cash expense not found'; end if;
 if p_approve then update public.dv_accounting_petty_cash_transactions set approval_note=nullif(trim(p_note),''),approved_by=auth.uid(),approved_at=now() where id=t.id; result:=public.dv_accounting_petty_cash_post_expense(t.id); return result||jsonb_build_object('approval_status','APPROVED'); end if;
 if not p_cash_returned then raise exception 'Confirm that the cash has been returned to the petty cash custodian before rejecting this expense'; end if;
 if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'A rejection reason is required'; end if;
 update public.dv_accounting_petty_cash_transactions set approval_status='REJECTED',approval_note=trim(p_note),approved_by=auth.uid(),approved_at=now() where id=t.id;
 return jsonb_build_object('transaction_id',t.id,'approval_status','REJECTED','cash_returned',true);
end $$;
