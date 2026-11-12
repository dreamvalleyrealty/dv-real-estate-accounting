-- Protect trade submissions that have become part of the accounting/compliance record.
-- Drafts with no transaction and no documents remain removable.
create or replace function public.dv_accounting_protect_trade_submission_delete()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if old.transaction_id is not null
     or exists (
       select 1
       from public.dv_accounting_transactions t
       where t.id = old.transaction_id
     )
     or exists (
       select 1
       from public.dv_accounting_agent_trade_documents d
       where d.submission_id = old.id
     )
     or upper(coalesce(old.status, 'DRAFT')) <> 'DRAFT'
  then
    raise exception
      'This trade submission cannot be deleted because it is linked to an accounting transaction, contains trade documents, or has entered review. Return or correct the trade instead.';
  end if;
  return old;
end;
$function$;

drop trigger if exists trg_dv_protect_trade_submission_delete
  on public.dv_accounting_agent_trade_submissions;
create trigger trg_dv_protect_trade_submission_delete
before delete on public.dv_accounting_agent_trade_submissions
for each row
execute function public.dv_accounting_protect_trade_submission_delete();

-- Keep a previously established accounting link. The application must use its
-- controlled return/correction workflow rather than silently orphaning a trade.
create or replace function public.dv_accounting_protect_trade_transaction_link()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if old.transaction_id is not null
     and new.transaction_id is null
     and exists (
       select 1 from public.dv_accounting_transactions t
       where t.id = old.transaction_id
     )
  then
    raise exception
      'The linked accounting transaction cannot be detached from this trade submission.';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_dv_protect_trade_transaction_link
  on public.dv_accounting_agent_trade_submissions;
create trigger trg_dv_protect_trade_transaction_link
before update of transaction_id on public.dv_accounting_agent_trade_submissions
for each row
execute function public.dv_accounting_protect_trade_transaction_link();
