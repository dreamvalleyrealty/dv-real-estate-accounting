create or replace function public.dv_accounting_validate_seller_settlement()
returns trigger language plpgsql set search_path=public as $function$
declare v_commission_total numeric(14,2);
begin
 new.updated_at:=now();
 v_commission_total:=round(coalesce(new.listing_commission_amount,0)+coalesce(new.cooperating_commission_amount,0)+coalesce(new.commission_hst_amount,0),2);
 if new.status in ('SELLER_PAID','COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
  if not public.dv_accounting_seller_proceeds_satisfied(new.id) then
   raise exception 'Seller must be paid in full before this settlement can advance.';
  end if;
  -- A zero-proceeds settlement has no seller disbursement and therefore no seller payment reference.
  if coalesce(new.seller_proceeds_amount,0)>0.009 and
    (coalesce(nullif(trim(new.seller_payment_reference),''),'')='' or new.seller_payment_date is null) then
   raise exception 'Record the seller payment reference and date before advancing.';
  end if;
 end if;
 if new.status in ('COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
  if new.commission_transfer_amount<>v_commission_total then
   raise exception 'Commission trust transfer must equal listing commission plus cooperating commission plus HST.';
  end if;
  if coalesce(nullif(trim(new.commission_transfer_reference),''),'')='' or new.commission_transfer_date is null then
   raise exception 'Record the commission trust transfer reference and date before advancing.';
  end if;
  if new.real_estate_trust_account_id is null or new.commission_trust_account_id is null
    or new.real_estate_trust_account_id=new.commission_trust_account_id then
   raise exception 'Select two different trust accounts for the commission transfer.';
  end if;
 end if;
 if new.status in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED')
    and not public.dv_accounting_seller_proceeds_satisfied(new.id) then
  raise exception 'Commission Payroll is blocked until the seller is fully paid.';
 end if;
 if new.status='PAYMENTS_COMPLETED' then
  if new.listing_agent_paid_amount+new.cooperating_brokerage_paid_amount>new.commission_transfer_amount then
   raise exception 'Recorded commission payments cannot exceed the transferred commission funds.';
  end if;
  new.payments_completed_at:=coalesce(new.payments_completed_at,now());
 end if;
 return new;
end;
$function$;