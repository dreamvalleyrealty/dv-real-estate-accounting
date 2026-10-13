-- Expand the category list into a basic brokerage chart of accounts.
alter table public.dv_accounting_categories
  drop constraint if exists dv_accounting_categories_category_type_check;
alter table public.dv_accounting_categories
  add constraint dv_accounting_categories_category_type_check
  check (category_type in ('INCOME','EXPENSE','ASSET','CURRENT_LIABILITY','LONG_TERM_LIABILITY','EQUITY','TRUST_ASSET','TRUST_LIABILITY'));

with seed(code,name,category_type,description) as (
 values
 ('AST-CASH-OPER','Operating Bank Accounts','ASSET','Operating bank and cash balances; reconcile to bank statements.'),
 ('AST-AR','Accounts Receivable','ASSET','Amounts billed and owed to the brokerage.'),
 ('AST-AGENT-AR','Agent Receivables','ASSET','Desk fees, lead fees, advances and other amounts owed by agents.'),
 ('AST-HST-ITC','HST Recoverable / Input Tax Credits','ASSET','Eligible HST paid on business purchases, subject to CRA rules.'),
 ('AST-PREPAID','Prepaid Expenses','ASSET','Payments for services or coverage relating to future periods.'),
 ('AST-DEP','Security and Utility Deposits','ASSET','Refundable deposits held by landlords or service providers.'),
 ('AST-FIXED','Furniture, Fixtures and Equipment','ASSET','Capital assets recorded at cost, with depreciation tracked separately.'),
 ('AST-ACCUM-DEP','Accumulated Depreciation','ASSET','Contra-asset account for accumulated depreciation; present as a reduction of fixed assets.'),
 ('AST-SOFTWARE','Capitalized Software / Intangibles','ASSET','Use only where capitalization is appropriate under the accounting policy.'),
 ('AST-OTHER','Other Assets','ASSET','Other business assets requiring review and classification.'),
 ('LIB-AP','Accounts Payable','CURRENT_LIABILITY','Unpaid supplier and vendor invoices.'),
 ('LIB-ACCRUED','Accrued Expenses Payable','CURRENT_LIABILITY','Expenses incurred but not yet paid or invoiced.'),
 ('LIB-HST','HST Payable','CURRENT_LIABILITY','Net HST payable calculated through the HST module.'),
 ('LIB-CPP','CPP Payable','CURRENT_LIABILITY','Employee and employer CPP amounts payable.'),
 ('LIB-EI','EI Payable','CURRENT_LIABILITY','Employee and employer EI amounts payable.'),
 ('LIB-PAYROLL-TAX','Payroll Income Tax Withheld','CURRENT_LIABILITY','Income tax deducted from employee pay and not yet remitted.'),
 ('LIB-WAGES','Wages and Vacation Pay Payable','CURRENT_LIABILITY','Earned wages, vacation pay and other payroll amounts outstanding.'),
 ('LIB-AGENT-COMM','Agent Commission Payable','CURRENT_LIABILITY','Commission amounts approved and owed to agents.'),
 ('LIB-COOP-COMM','Cooperating Brokerage Commission Payable','CURRENT_LIABILITY','Commission amounts owed to cooperating brokerages.'),
 ('LIB-REFERRAL','Referral Fees Payable','CURRENT_LIABILITY','Referral fees owed to agents or brokerages.'),
 ('LIB-CREDIT-CARD','Credit Cards Payable','CURRENT_LIABILITY','Outstanding business credit card balances.'),
 ('LIB-CUSTOMER-DEPOSIT','Customer Deposits / Unearned Revenue','CURRENT_LIABILITY','Amounts received before the related service is earned.'),
 ('LIB-SHAREHOLDER-ST','Shareholder / Director Loan - Current','CURRENT_LIABILITY','Amounts due to shareholders or directors within the short term.'),
 ('LIB-LOAN-ST','Current Portion of Loans','CURRENT_LIABILITY','Principal due within the next 12 months.'),
 ('LIB-LEASE-ST','Current Lease Liability','CURRENT_LIABILITY','Current portion of applicable lease obligations.'),
 ('LIB-OTHER-ST','Other Current Liabilities','CURRENT_LIABILITY','Other short-term obligations requiring review.'),
 ('LIB-LOAN-LT','Long-Term Loans Payable','LONG_TERM_LIABILITY','Loan principal due beyond 12 months.'),
 ('LIB-SHAREHOLDER-LT','Shareholder / Director Loan - Long-Term','LONG_TERM_LIABILITY','Amounts due to shareholders or directors beyond the short term.'),
 ('LIB-LEASE-LT','Long-Term Lease Liability','LONG_TERM_LIABILITY','Long-term portion of applicable lease obligations.'),
 ('LIB-OTHER-LT','Other Long-Term Liabilities','LONG_TERM_LIABILITY','Other obligations due beyond 12 months.'),
 ('EQ-OWNER','Owner / Shareholder Equity','EQUITY','Owner or shareholder capital and equity.'),
 ('EQ-RETAINED','Retained Earnings','EQUITY','Accumulated prior-period earnings or losses.'),
 ('EQ-CURRENT','Current Year Earnings','EQUITY','Current-period net income or loss; normally calculated from the ledger.'),
 ('EQ-DRAWINGS','Owner Drawings / Dividends','EQUITY','Owner withdrawals or dividends, classified according to entity type.'),
 ('TR-AST-REAL','Real Estate Trust Bank Account','TRUST_ASSET','Trust cash held for clients; never use for operating expenses.'),
 ('TR-AST-COMM','Commission Trust Bank Account','TRUST_ASSET','Commission trust cash; reconcile separately to bank and ledger.'),
 ('TR-AST-OTHER','Other Trust Cash / Deposits','TRUST_ASSET','Other regulated trust cash or deposits, if applicable.'),
 ('TR-LIB-CLIENT','Client Trust Funds Payable','TRUST_LIABILITY','Amounts held in trust and owed to individual clients or transactions.'),
 ('TR-LIB-COMM','Commission Trust Funds Payable','TRUST_LIABILITY','Commission trust funds held pending authorized disbursement.'),
 ('TR-LIB-OTHER','Other Trust Obligations','TRUST_LIABILITY','Other trust liabilities supported by client-level subsidiary records.')
)
insert into public.dv_accounting_categories(company_id,name,code,category_type,description,active)
select c.id,s.name,s.code,s.category_type,s.description,true
from public.dv_accounting_companies c cross join seed s
where not exists (
 select 1 from public.dv_accounting_categories x
 where x.company_id=c.id and x.code=s.code and x.category_type=s.category_type
);
