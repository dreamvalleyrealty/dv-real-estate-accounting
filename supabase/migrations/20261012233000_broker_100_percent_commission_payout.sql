CREATE OR REPLACE FUNCTION public.dv_accounting_calculate_commission_fees(p_agent_id uuid, p_transaction_id uuid, p_gross_commission numeric, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 85;
  desk_fee numeric := 0;
  admin_type text := 'AMOUNT';
  admin_value numeric := 0;
  lead_type text := 'AMOUNT';
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
  is_broker_100 boolean := false;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  SELECT * INTO fs FROM public.dv_accounting_agent_fee_settings WHERE agent_id=p_agent_id;
  IF fs.fee_plan_id IS NOT NULL THEN
    SELECT * INTO plan FROM public.dv_accounting_fee_plans WHERE id=fs.fee_plan_id;
  END IF;
  is_broker_100 := regexp_replace(lower(coalesce(plan.name,'')), '[^a-z0-9]', '', 'g') LIKE 'broker100%';

  SELECT * INTO rule
  FROM public.dv_accounting_agent_fee_rules
  WHERE agent_id=p_agent_id AND active
    AND effective_from<=p_as_of
    AND (effective_to IS NULL OR effective_to>=p_as_of)
  ORDER BY effective_from DESC,created_at DESC LIMIT 1;

  IF t.transaction_type='LEASE' THEN
    split_pct:=COALESCE(
      rule.commission_split_lease_percent,
      fs.commission_split_lease_override_percent,
      plan.commission_split_lease_percent,
      100
    );
  ELSE
    split_pct:=COALESCE(
      rule.commission_split_buy_sell_percent,
      fs.commission_split_buy_sell_override_percent,
      fs.commission_split_override_percent,
      plan.commission_split_buy_sell_percent,
      plan.commission_split_percent,
      85
    );
  END IF;

  -- Broker 100% is a brokerage-retained plan; it overrides any fee-rule or agent split override.
  IF is_broker_100 THEN split_pct:=0; END IF;

  desk_fee:=COALESCE(rule.desk_fee,fs.desk_fee_override,plan.desk_fee,0);

  IF t.market_segment='COMMERCIAL' AND t.transaction_type='LEASE' THEN
    admin_type:=COALESCE(rule.admin_fee_commercial_lease_type,fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_commercial_lease_value,fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
  ELSIF t.market_segment='COMMERCIAL' THEN
    admin_type:=COALESCE(rule.admin_fee_commercial_buy_sell_type,fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_commercial_buy_sell_value,fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
  ELSIF t.transaction_type='LEASE' THEN
    admin_type:=COALESCE(rule.admin_fee_lease_type,fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_lease_value,fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
  ELSE
    admin_type:=COALESCE(rule.admin_fee_buy_sell_type,fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_buy_sell_value,fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
  END IF;

  IF t.transaction_type='LEASE' THEN
    lead_type:=COALESCE(rule.lead_fee_lease_type,fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
    lead_value:=COALESCE(rule.lead_fee_lease_value,fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
  ELSE
    lead_type:=COALESCE(rule.lead_fee_buy_sell_type,fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
    lead_value:=COALESCE(rule.lead_fee_buy_sell_value,fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
  END IF;

  agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);
  IF admin_type='PERCENT' THEN admin_fee:=ROUND(COALESCE(p_gross_commission,0)*admin_value/100,2); ELSE admin_fee:=ROUND(admin_value,2); END IF;

  IF COALESCE(t.is_brokerage_lead,false) THEN
    IF lead_type='PERCENT' THEN lead_fee:=ROUND(COALESCE(p_gross_commission,0)*lead_value/100,2); ELSE lead_fee:=ROUND(lead_value,2); END IF;
  ELSE
    lead_fee:=0;
  END IF;

  RETURN jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'brokerage_share_percent',100-split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'lead_fee_applies',COALESCE(t.is_brokerage_lead,false),
    'total_transaction_fees',ROUND(admin_fee+lead_fee,2),
    'net_transaction_commission',GREATEST(ROUND(agent_share-admin_fee-lead_fee-desk_fee,2),0),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
END $function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_finalize_transaction(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 t public.dv_accounting_transactions%rowtype;
 company uuid;
 je uuid;
 ar uuid; rev uuid; hst uuid; agent_exp uuid; agent_pay uuid;
 coop_exp uuid; coop_pay uuid; hst_rec uuid; trust_bank_gl uuid; trust_liability uuid;
 agent_amt numeric(14,2);
 is_broker_100 boolean := false;
 c record;
 tr record;
 coop_hst numeric(14,2);
begin
 select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if t.status='FINALIZED' then return jsonb_build_object('ok',true,'message','Already finalized'); end if;
 company:=t.company_id;
 if company is null then
   select id into company from public.dv_accounting_companies order by created_at limit 1;
   if company is null then raise exception 'Create a company in Settings before finalizing transactions'; end if;
   update public.dv_accounting_transactions set company_id=company where id=t.id;
 end if;

 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values
 (company,'1150','Commission Receivable','ASSET'),
 (company,'4000','Commission Revenue','REVENUE'),
 (company,'2400','HST Payable','LIABILITY'),
 (company,'5200','Agent Commission Expense','EXPENSE'),
 (company,'2200','Agent Commissions Payable','LIABILITY'),
 (company,'2100','Co-operating Brokerage Payable','LIABILITY'),
 (company,'5250','Co-operating Brokerage Commission Expense','EXPENSE'),
 (company,'1180','HST Recoverable / Input Tax Credits','ASSET'),
 (company,'1015','Real Estate Trust Bank','ASSET'),
 (company,'2300','Real Estate Trust Liabilities','LIABILITY')
 on conflict(company_id,code) do nothing;

 select id into ar from public.dv_accounting_gl_accounts where company_id=company and code='1150';
 select id into rev from public.dv_accounting_gl_accounts where company_id=company and code='4000';
 select id into hst from public.dv_accounting_gl_accounts where company_id=company and code='2400';
 select id into agent_exp from public.dv_accounting_gl_accounts where company_id=company and code='5200';
 select id into agent_pay from public.dv_accounting_gl_accounts where company_id=company and code='2200';
 select id into coop_exp from public.dv_accounting_gl_accounts where company_id=company and code='5250';
 select id into coop_pay from public.dv_accounting_gl_accounts where company_id=company and code='2100';
 select id into hst_rec from public.dv_accounting_gl_accounts where company_id=company and code='1180';
 select id into trust_bank_gl from public.dv_accounting_gl_accounts where company_id=company and code='1015';
 select id into trust_liability from public.dv_accounting_gl_accounts where company_id=company and code='2300';

 IF t.agent_id IS NOT NULL THEN
   SELECT EXISTS(
     SELECT 1
     FROM public.dv_accounting_agent_fee_settings fs
     JOIN public.dv_accounting_fee_plans fp ON fp.id=fs.fee_plan_id
     WHERE fs.agent_id=t.agent_id
       AND regexp_replace(lower(coalesce(fp.name,'')), '[^a-z0-9]', '', 'g') LIKE 'broker100%'
   ) INTO is_broker_100;
 END IF;
 agent_amt:=CASE WHEN is_broker_100 THEN 0 ELSE coalesce(t.agent_commission,0) END;
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(company,coalesce(t.close_date,t.transaction_date,current_date),'TRANSACTION',t.id,'Finalize real estate transaction') returning id into je;

 -- Brokerage commission receivable and revenue, plus HST collected.
 if coalesce(t.gross_commission,0)<>0 or coalesce(t.hst_amount,0)<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,ar,coalesce(t.gross_commission,0)+coalesce(t.hst_amount,0),0),
         (je,rev,0,coalesce(t.gross_commission,0));
   if coalesce(t.hst_amount,0)<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,hst,0,t.hst_amount);
   end if;
 end if;

 -- Agent commission expense and amount due to the agent.
 if agent_amt<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,agent_exp,agent_amt,0),(je,agent_pay,0,agent_amt);
 end if;

 -- Co-operating brokerage commissions: expense + any eligible HST ITC, offset by A/P.
 for c in
   select tc.*, coalesce(eb.charges_hst,true) as brokerage_charges_hst
   from public.dv_accounting_transaction_commissions tc
   left join public.dv_accounting_external_brokerages eb on eb.id=tc.brokerage_id
   where tc.transaction_id=t.id and tc.settlement_direction='PAYABLE'
 loop
   coop_hst:=case when c.brokerage_charges_hst then coalesce(c.hst_amount,0) else 0 end;
   if coalesce(c.amount,0)+coop_hst<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_exp,coalesce(c.amount,0),0);
     if coop_hst<>0 then
       insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
       values(je,hst_rec,coop_hst,0);
     end if;
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_pay,0,coalesce(c.amount,0)+coop_hst);
   end if;
 end loop;

 -- Only post a trust receipt when Dream Valley actually holds and has received the deposit.
 select * into tr
 from public.dv_accounting_transaction_trust
 where transaction_id=t.id and we_hold_deposit='YES' and received='YES' and amount>0
 order by created_at desc limit 1;
 if found then
   if tr.trust_bank_account_id is null then
     raise exception 'Select the Real Estate Trust bank account before finalizing a received deposit';
   end if;
   if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=tr.trust_bank_account_id and b.account_type='REAL_ESTATE_TRUST' and b.active=true) then
     raise exception 'The selected deposit account must be an active Real Estate Trust account';
   end if;
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,trust_bank_gl,tr.amount,0),(je,trust_liability,0,tr.amount);
 end if;

 update public.dv_accounting_transactions
 set status='FINALIZED', finalized_at=now(), finalized_date=coalesce(finalized_date,current_date), company_id=company,
     agent_commission=agent_amt,
     commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false) THEN agent_amt ELSE commission_approved_agent_payable END
 where id=t.id;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'agent_commission',agent_amt);
end $function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_issue_commission_cheque(p_commission_id uuid, p_cheque_number text DEFAULT NULL::text, p_cheque_date date DEFAULT CURRENT_DATE, p_adjustment numeric DEFAULT 0, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  gross_amt numeric(14,2);
  agent_share numeric(14,2);
  transaction_fees numeric(14,2);
  outstanding_fees numeric(14,2);
  total_fees numeric(14,2);
  net_agent_before_hst numeric(14,2);
  hst_rate numeric(6,3) := 13;
  agent_hst numeric(14,2) := 0;
  client_hst numeric(14,2) := 0;
  brokerage_hst numeric(14,2) := 0;
  ai record;
  lead_to_restore numeric(14,2) := 0;
BEGIN
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF c.status='PAID' THEN RAISE EXCEPTION 'Commission has already been paid'; END IF;
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  -- Last-line safeguard: restore a saved lead deduction for non-lead transactions
  -- before issuing payment. The condition prevents a second restoration.
  IF NOT COALESCE(t.is_brokerage_lead,false) THEN
    SELECT lead_fee, net_payable INTO ai
    FROM public.dv_accounting_transaction_agent_info
    WHERE transaction_id=c.transaction_id
    LIMIT 1;
    lead_to_restore:=GREATEST(COALESCE(ai.lead_fee,0),0);
    IF lead_to_restore>0
       AND ROUND(COALESCE(c.agent_share,0),2) <= ROUND(COALESCE(ai.net_payable,c.agent_share,0),2)+0.01 THEN
      UPDATE public.dv_accounting_commissions
      SET agent_share=ROUND(COALESCE(agent_share,0)+lead_to_restore,2),
          brokerage_share=GREATEST(ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+lead_to_restore),2),0)
      WHERE id=c.id;
      UPDATE public.dv_accounting_transactions
      SET agent_commission=ROUND(COALESCE(agent_commission,0)+lead_to_restore,2),
          commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
            THEN ROUND(COALESCE(commission_approved_agent_payable,0)+lead_to_restore,2)
            ELSE commission_approved_agent_payable END
      WHERE id=c.transaction_id;
      UPDATE public.dv_accounting_transaction_agent_info
      SET lead_fee=0, lead_fee_applies=false,
          net_payable=ROUND(COALESCE(net_payable,0)+lead_to_restore,2)
      WHERE transaction_id=c.transaction_id;
      SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;
      SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
    END IF;
  END IF;

  SELECT * INTO agent FROM public.dv_accounting_agents WHERE id=c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt:=COALESCE(c.gross_commission,t.gross_commission,0);
  calc:=public.dv_accounting_calculate_commission_fees(c.agent_id,c.transaction_id,gross_amt,COALESCE(t.transaction_date,p_cheque_date));
  transaction_fees:=ROUND(COALESCE((calc->>'admin_fee')::numeric,0)+COALESCE((calc->>'lead_fee')::numeric,0)+COALESCE((calc->>'desk_fee')::numeric,0),2);

  -- Calculate agent payable from GCI less applicable transaction fees; GCI is already the agent gross commission.
  -- This prevents a stale approved amount from preserving an incorrect lead deduction
  -- or omitting the configured admin fee.
  -- Respect the calculated plan split; gross commission is not automatically the agent's share.
  agent_share:=GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0);

  UPDATE public.dv_accounting_commissions
  SET agent_share=GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0),
      brokerage_share=GREATEST(ROUND(gross_amt-GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0),2),0)
  WHERE id=c.id;
  UPDATE public.dv_accounting_transactions
  SET agent_commission=agent_share,
      commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
        THEN agent_share ELSE commission_approved_agent_payable END
  WHERE id=t.id;
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;

  SELECT COALESCE(SUM(amount),0) INTO outstanding_fees
  FROM public.dv_accounting_commission_charges
  WHERE agent_id=c.agent_id AND status='OPEN' AND applied_to_cheque_id IS NULL
    AND COALESCE(commission_id::text,'')<>c.id::text;
  total_fees:=ROUND(outstanding_fees,2);
  net_agent_before_hst:=GREATEST(agent_share-total_fees,0);

  IF NULLIF(BTRIM(COALESCE(agent.hst_number,'')),'') IS NOT NULL THEN
    agent_hst:=ROUND(net_agent_before_hst*hst_rate/100,2);
  END IF;
  client_hst:=CASE WHEN COALESCE(t.hst_amount,0)>0 THEN ROUND(t.hst_amount,2) ELSE ROUND(gross_amt*hst_rate/100,2) END;
  brokerage_hst:=GREATEST(client_hst-agent_hst,0);

  INSERT INTO public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,agent_share,total_fees,adjustments,status,issued_at,notes,
    agent_hst_number,agent_hst_rate,agent_hst_amount,brokerage_hst_amount,client_hst_amount
  ) VALUES(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,gross_amt,agent_share,total_fees,COALESCE(p_adjustment,0),'ISSUED',now(),p_notes,
    NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),hst_rate,agent_hst,brokerage_hst,client_hst
  ) RETURNING id INTO cheque_id;

  INSERT INTO public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,source_rule_id
  )
  SELECT c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
    CASE WHEN x.charge_type IN ('ADMIN_FEE','LEAD_FEE') THEN (calc->>'fee_rule_id')::uuid ELSE NULL END
  FROM jsonb_to_recordset(jsonb_build_array(
    jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',0),
    jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',0)
  )) AS x(charge_type text,description text,amount numeric)
  WHERE x.amount>0;

  UPDATE public.dv_accounting_commissions SET status='PAID',paid_date=p_cheque_date WHERE id=c.id;

  RETURN jsonb_build_object(
    'cheque_id',cheque_id,'commission_id',c.id,'agent_share',agent_share,
    'agent_net_before_hst',net_agent_before_hst,'agent_hst_number',NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),
    'agent_hst_rate',hst_rate,'agent_hst_amount',agent_hst,'brokerage_hst_amount',brokerage_hst,'client_hst_amount',client_hst,
    'total_fees',total_fees,'transaction_fees',transaction_fees,'lead_fee_amount',COALESCE((calc->>'lead_fee')::numeric,0),
    'net_amount',net_agent_before_hst+COALESCE(p_adjustment,0)+agent_hst,'calculation',calc
  );
END $function$;
