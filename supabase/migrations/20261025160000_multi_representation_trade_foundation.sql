-- Multi-representation trade foundation.
-- Each side remains a distinct submission so documents and reviews can be tracked separately.
-- The UI/workflow migration will use these fields to link submissions to one transaction.
alter table public.dv_accounting_agent_trade_submissions
  add column if not exists representation_group_id uuid,
  add column if not exists representation_side text;

alter table public.dv_accounting_agent_trade_submissions
  drop constraint if exists dv_accounting_agent_trade_submissions_representation_side_check;

alter table public.dv_accounting_agent_trade_submissions
  add constraint dv_accounting_agent_trade_submissions_representation_side_check
  check (representation_side is null or representation_side in ('LANDLORD','TENANT','SELLER','BUYER'));

create index if not exists idx_agent_trade_submissions_representation_group
  on public.dv_accounting_agent_trade_submissions(representation_group_id)
  where representation_group_id is not null;

alter table public.dv_accounting_agent_trade_documents
  add column if not exists representation_side text;

alter table public.dv_accounting_agent_trade_documents
  drop constraint if exists dv_accounting_agent_trade_documents_representation_side_check;

alter table public.dv_accounting_agent_trade_documents
  add constraint dv_accounting_agent_trade_documents_representation_side_check
  check (representation_side is null or representation_side in ('LANDLORD','TENANT','SELLER','BUYER'));

create index if not exists idx_agent_trade_documents_side
  on public.dv_accounting_agent_trade_documents(submission_id, representation_side);

comment on column public.dv_accounting_agent_trade_submissions.representation_group_id is
  'Groups separate landlord/tenant or seller/buyer representation submissions for a single transaction.';
comment on column public.dv_accounting_agent_trade_submissions.representation_side is
  'Side represented by the agent who owns this submission.';
comment on column public.dv_accounting_agent_trade_documents.representation_side is
  'Representation side the document supports; null means shared/general paperwork.';