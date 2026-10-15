-- Correct commission cheque deductions: include all outstanding charges regardless of charge creation date. Desk fees remain opt-in and include HST.
create or replace function public.dv_accounting_issue_commission_cheque(
 p_commission_id uuid,p_cheque_number text default null,p_cheque_date date default current_date,
 p_adjustment numeric default 0,p_notes text default null,p_deduct_desk_fees boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
 c public.dv_accounting_commissions%rowtype; t public.dv_accounting_transactions%rowtype; calc jsonb;
 cheque_id uuid; transaction_fees numeric(14,2); recurring_fees numeric(14,2); service_fees numeric(14,2);
 desk_fees numeric(14,2); general_fees numeric(14,2); total_fees numeric(14,2); agent_share numeric(14,2);
begin
 select * into c from public.dv_accounting_commissions where id=p_commission_id for update;
 if not found then raise exception 'Commission record not found'; end if;
 if c.status='PAID' then raise exception 'Commission has already been paid'; end if;
 select * into t from public.dv_accounting_transactions where id=c.transaction_id;
 if not found then raise exception 'Transaction not found'; end if;
 calc:=public.dv_accounting_calculate_commission_fees(c.agent_id,c.transaction_id,coalesce(c.gross_commission,t.gross_commission,0),coalesce(t.transaction_date,p_cheque_date));
 agent_share:=coalesce((calc->>'agent_share')::numeric,0);
 transaction_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);
 select coalesce(sum(amount),0) into recurring_fees from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='RECURRING_FEE' and status='OPEN' and applied_to_cheque_id is null;
 select coalesce(sum(amount),0) into service_fees from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='ADD_ON_SERVICE' and status='OPEN' and applied_to_cheque_id is null;
 select coalesce(sum(amount + case when hst_applicable then coalesce(hst_amount,0) else 0 end),0) into desk_fees from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type='DESK_FEE' and status='OPEN' and applied_to_cheque_id is null;
 select coalesce(sum(amount + case when hst_applicable then coalesce(hst_amount,0) else 0 end),0) into general_fees from public.dv_accounting_commission_charges
 where agent_id=c.agent_id and charge_type in ('GENERAL_EXPENSE','GENERAL_EXP','OTHER_FEE') and status='OPEN' and applied_to_cheque_id is null;
 if not coalesce(p_deduct_desk_fees,false) then desk_fees:=0; end if;
 total_fees:=transaction_fees+recurring_fees+service_fees+desk_fees+general_fees;
 insert into public.dv_accounting_commission_cheques(company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,agent_share,total_fees,adjustments,status,issued_at,notes)
 values(t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,coalesce(c.gross_commission,t.gross_commission,0),agent_share,total_fees,coalesce(p_adjustment,0),'ISSUED',now(),p_notes) returning id into cheque_id;
 update public.dv_accounting_commission_charges set status='APPLIED',applied_to_cheque_id=cheque_id
 where agent_id=c.agent_id and charge_type in ('GENERAL_EXPENSE','GENERAL_EXP','OTHER_FEE') and status in ('OPEN','PARTIAL') and applied_to_cheque_id is null;
 insert into public.dv_accounting_commission_charges(commission_id,transaction_id,agent_id,charge_type,description,amount,source_rule_id,status,applied_to_cheque_id)
 select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
 case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end,'APPLIED',cheque_id
 from jsonb_to_recordset(jsonb_build_array(
 jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
 jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
 )) as x(charge_type text,description text,amount numeric) where x.amount<>0;
 update public.dv_accounting_commission_charges set status='APPLIED',applied_to_cheque_id=cheque_id
 where agent_id=c.agent_id and charge_type in ('RECURRING_FEE','ADD_ON_SERVICE') and status='OPEN' and applied_to_cheque_id is null;
 if coalesce(p_deduct_desk_fees,false) then
 update public.dv_accounting_commission_charges set status='APPLIED',applied_to_cheque_id=cheque_id
 where agent_id=c.agent_id and charge_type='DESK_FEE' and status='OPEN' and applied_to_cheque_id is null;
 end if;
 update public.dv_accounting_commissions set status='PAID',paid_date=p_cheque_date where id=c.id;
 return jsonb_build_object('cheque_id',cheque_id,'commission_id',c.id,'agent_share',agent_share,'transaction_fees',transaction_fees,
 'recurring_fees',recurring_fees,'service_fees',service_fees,'desk_fees',desk_fees,'general_expense',general_fees,'total_fees',total_fees,
 'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),'calculation',calc);
end $$;
revoke all on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text,boolean) from public,anon;
grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text,boolean) to authenticated;