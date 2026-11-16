-- Invoice administration: safe deletion, reusable daily numbers, and prior balance snapshot.
alter table public.dv_agent_invoices
  add column if not exists prior_balance_amount numeric(14,2) not null default 0
  check (prior_balance_amount >= 0);

create or replace function public.dv_agent_invoice_capture_prior_balance()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  select coalesce(sum(balance_amount),0) into new.prior_balance_amount
  from public.dv_agent_invoices
  where agent_id=new.agent_id and status<>'Void';
  return new;
end;
$$;
drop trigger if exists trg_dv_agent_invoice_capture_prior_balance on public.dv_agent_invoices;
create trigger trg_dv_agent_invoice_capture_prior_balance
before insert on public.dv_agent_invoices
for each row execute function public.dv_agent_invoice_capture_prior_balance();

create or replace function public.dv_agent_invoice_number(p_day date default current_date)
returns text language plpgsql security definer set search_path=public as $$
declare
  v_next integer;
  v_candidate integer;
  v_number text;
begin
  insert into public.dv_agent_invoice_daily_sequences(invoice_day,last_number)
  values(p_day,0) on conflict(invoice_day) do nothing;
  perform 1 from public.dv_agent_invoice_daily_sequences where invoice_day=p_day for update;
  for v_candidate in 1..99 loop
    v_number:=to_char(p_day,'YYYYMMDD')||lpad(v_candidate::text,2,'0');
    if not exists(select 1 from public.dv_agent_invoices where invoice_number=v_number) then
      v_next:=v_candidate;
      exit;
    end if;
  end loop;
  if v_next is null then raise exception 'Daily invoice number limit reached'; end if;
  update public.dv_agent_invoice_daily_sequences set last_number=v_next where invoice_day=p_day;
  return to_char(p_day,'YYYYMMDD')||lpad(v_next::text,2,'0');
end;
$$;

create or replace function public.dv_delete_agent_invoice(p_invoice_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.dv_is_management_user() then
    raise exception 'Only management users can delete agent invoices';
  end if;
  if not exists(select 1 from public.dv_agent_invoices where id=p_invoice_id) then
    raise exception 'Invoice not found';
  end if;
  if exists(select 1 from public.dv_agent_invoice_payments where invoice_id=p_invoice_id) then
    raise exception 'This invoice has payment history and cannot be deleted. Keep it for accounting records.';
  end if;
  delete from public.dv_agent_invoices where id=p_invoice_id;
end;
$$;
revoke all on function public.dv_delete_agent_invoice(uuid) from public,anon;
grant execute on function public.dv_delete_agent_invoice(uuid) to authenticated;
