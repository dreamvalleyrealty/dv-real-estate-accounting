-- 0032: transaction commission approval/closure and automatic commission payroll queue

alter table public.dv_accounting_transactions
  add column if not exists commission_approved boolean not null default false,
  add column if not exists commission_approved_at timestamptz,
  add column if not exists commission_approved_amount numeric(14,2) not null default 0,
  add column if not exists commission_approved_agent_payable numeric(14,2) not null default 0,
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid,
  add column if not exists commission_payroll_status text not null default 'NOT_READY',
  add column if not exists commission_id uuid references public.dv_accounting_commissions(id);

alter table public.dv_accounting_transactions drop constraint if exists dv_accounting_transactions_commission_payroll_status_check;
alter table public.dv_accounting_transactions add constraint dv_accounting_transactions_commission_payroll_status_check
  check (commission_payroll_status in ('NOT_READY','READY','PAID'));

create index if not exists idx_dv_transactions_commission_payroll
  on public.dv_accounting_transactions(commission_payroll_status,close_date);

create or replace function public.dv_accounting_approve_transaction_commission(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.dv_accounting_transactions%rowtype;
begin
  select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
  if not found then raise exception 'Transaction not found'; end if;
  if t.status='CLOSED' then raise exception 'Closed transaction cannot be changed'; end if;
  if coalesce(t.gross_commission,0)<=0 and coalesce(t.agent_commission,0)<=0 then
    raise exception 'Enter and verify the commission amount before approval';
  end if;
  update public.dv_accounting_transactions
  set commission_approved=true,
      commission_approved_at=coalesce(commission_approved_at,now()),
      commission_approved_amount=coalesce(t.gross_commission,0),
      commission_approved_agent_payable=coalesce(t.agent_commission,0)
  where id=t.id;
  return jsonb_build_object('ok',true,'transaction_id',t.id,'approved_amount',coalesce(t.gross_commission,0),'agent_payable',coalesce(t.agent_commission,0));
end $$;

create or replace function public.dv_accounting_close_transaction(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  t public.dv_accounting_transactions%rowtype;
  commission_id uuid;
  agent_amt numeric(14,2);
  gross_amt numeric(14,2);
begin
  select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
  if not found then raise exception 'Transaction not found'; end if;
  if t.status<>'FINALIZED' then raise exception 'Finalize the transaction accounting before closing it'; end if;
  if not coalesce(t.commission_approved,false) then raise exception 'Commission amount must be approved before closing the transaction'; end if;
  if t.close_date is null then raise exception 'Close date is required before closing the transaction'; end if;
  if t.agent_id is null then raise exception 'Deal agent is required before sending the commission to payroll'; end if;

  gross_amt:=coalesce(t.commission_approved_amount,t.gross_commission,0);
  agent_amt:=coalesce(t.commission_approved_agent_payable,t.agent_commission,0);
  commission_id:=t.commission_id;

  if commission_id is null then
    select id into commission_id from public.dv_accounting_commissions where transaction_id=t.id order by id limit 1;
    if commission_id is null then
      insert into public.dv_accounting_commissions(transaction_id,agent_id,gross_commission,brokerage_share,agent_share,status)
      values(t.id,t.agent_id,gross_amt,greatest(gross_amt-agent_amt,0),agent_amt,'UNPAID')
      returning id into commission_id;
    else
      update public.dv_accounting_commissions
      set agent_id=t.agent_id,gross_commission=gross_amt,brokerage_share=greatest(gross_amt-agent_amt,0),agent_share=agent_amt
      where id=commission_id;
    end if;
  else
    update public.dv_accounting_commissions
    set status=case when status='PAID' then status else 'UNPAID' end,
        agent_id=t.agent_id,gross_commission=gross_amt,brokerage_share=greatest(gross_amt-agent_amt,0),agent_share=agent_amt
    where id=commission_id;
  end if;

  update public.dv_accounting_transactions
  set status='CLOSED',closed_at=coalesce(closed_at,now()),closed_by=auth.uid(),
      commission_payroll_status=case when exists(
        select 1 from public.dv_accounting_commission_cheques ch
        where ch.commission_id=commission_id and ch.status='ISSUED'
      ) then 'PAID' else 'READY' end,
      commission_id=commission_id
  where id=t.id;

  return jsonb_build_object('ok',true,'transaction_id',t.id,'commission_id',commission_id,'commission_payroll_status','READY','agent_payable',agent_amt);
end $$;

revoke all on function public.dv_accounting_approve_transaction_commission(uuid) from public;
grant execute on function public.dv_accounting_approve_transaction_commission(uuid) to authenticated;
revoke all on function public.dv_accounting_close_transaction(uuid) from public;
grant execute on function public.dv_accounting_close_transaction(uuid) to authenticated;
