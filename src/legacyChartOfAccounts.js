const RAW = `
10001|Cash - Current Account|A
10002|Real Estate Trust Account|A
10004|Cash - Commission Trust Account|A
10005|Term Deposits - Buyers|A
10006|Cash - General Term Deposits|A
10009|Cash - Petty Cash|A
10010|Td - Commission Trust|A
10011|Td - Real Estate Trust|A
10012|Td - Operating Account|A
10013|Td - Danforth Branch - Operating|A
11000|Notes Receivables|A
12100|A/R - Agt's Recoverable- Gen Exp|A
12200|A/R - Commission From Deals|A
12500|A/R - Other|A
12999|A/R - Allowance|A
15000|Prepaid Expenses|A
16010|Land & Buildings|A
16020|Vehicles|A
16030|Office Furniture|A
16040|Office Equipment|A
16050|Computer Hardware|A
16060|Computer Software|A
16070|Leasehold Improvements|A
16080|Signs|A
16090|Franchise Cost|A
17010|Acc. Depr. - Building|A
17020|Acc. Depr. - Vehicles|A
17030|Acc. Depr. - Office Furniture|A
17040|Acc. Depr. - Office Equipment|A
17050|Acc. Depr. - Comp. Hardware|A
17060|Acc. Depr. - Comp. Software|A
17070|Acc. Amor. - Leaseholds|A
17080|Acc. Depr. - Signs|A
17090|Acc. Amor. - Franchise Costs|A
20000|Bank Operating Line|L
21000|A/P - Suppliers|L
21100|A/P - Other Brokers & Referrals|L
21300|Liability For Trust Funds Held|L
21500|Commission Payable|L
22000|Accrued Expenses|L
23000|Hst Collected|L
23001|Hst Input Tax Credit|L
23002|Agent's Hst Contra|L
23003|P.S.T. Collected|L
23004|P.S.T. Input Tax Credits|L
24000|F.I.T. Withheld|L
24001|E.I. Withheld|L
24002|C.P.P. Withheld|L
24500|Payroll Clearing|L
24700|Vacation Pay Payable|L
26000|Income Tax Payable|L
27000|Bank Loan #1|L
27010|Bank Loan #2|L
28000|Shareholder Loan - Sabbir Khan|L
28010|Shareholder Loan - #2|L
28020|Shareholder Loan - #3|L
29000|Suspense|L
30000|Preferred Stock|E
30010|Common Stock|E
30050|Dividend|E
39998|Retained Earnings - Open Bal.|E
39999|Retained Earnings - Y.T.D.|E
40100|Commission Income|S
42100|Interest Income|O
42200|Late Fee Income|O
43100|Other Income|O
43101|Event Income|O
43102|Split Fee Income|O
43103|Broker 100 Income|O
43104|Admin Fee Income|O
43196|Technology Fee|O
45100|Desk Fee Income|S
45101|Other Income|S
50100|Agent's Commission|C
51100|Commission To Other Brokers|C
60101|Equip. Rental - Computer|X
60102|Equip. Rental - Furniture|X
60199|Equip. Rental - Misc.|X
62101|Rent & Occ. - Rent Expense|X
62102|Rent & Occ. - Common Area|X
62103|Rent & Occ. - Utilities|X
62104|Rent & Occ. - Repairs & Maint.|X
62105|Rent & Occ. - Prop./Bus. Taxes|X
63101|Lic. & Ins. - Errors & Ommiss.|X
63102|Lic. & Ins. - Office Contents|X
63103|Lic. & Ins. - Licenses|X
63199|Lic. & Ins. - Misc.|X
63200|Hst Penalty & Interest|X
63201|Income Tax Penalty & Interest|X
64101|Selling - Mls Fees|X
64102|Selling - Signs|X
64103|Selling - Supplies|X
64104|Selling - Meetings|X
64105|Selling - Agent Bonus|X
64106|Selling - Website|X
64107|Selling - Photography|X
64199|Selling - Misc.|X
65101|Advertising - Classified|X
65102|Advertising - Other Medium|X
65103|Advertising - Yellow Pages|X
65104|Advertising - Institutional|X
65105|Advertising - Promotional|X
65199|Advertising - Misc.|X
66101|Recruiting Lunches|X
66102|Recruiting Gifts|X
66103|Recruiting Materials|X
66111|Staff Lunches|X
66112|Staff Gifts|X
66199|Misc. Recruiting|X
69101|Franchise Costs - Participation|X
69103|Franchise Costs - Advertising|X
69199|Franchise Costs - Misc.|X
70101|Payroll Exp. - Mgmt. Salaries|X
70102|Payroll Exp. - Salaries|X
70103|Payroll Exp. - Part-Time|X
70104|Payroll Exp. - Payroll|X
70105|Payroll Exp. - Health Insurance|X
70106|Payroll Exp. - E.H.T.|X
70107|Payroll Exp. - Manager's Bonus|X
70199|Payroll Exp. - Misc.|X
71101|Bank Charges - Interest|X
71102|Bank Charges - Loan Interest|X
71104|Bank Charges - Service Charges|X
71199|Bank Charges - Misc.|X
72101|Commun. Exp. - Telephone Lines|X
72102|Commun. Exp. - Long Distance|X
72103|Exp. - Internet|X
72104|Commun. Exp. - Cellular|X
72199|Commun. Exp. - Misc.|X
75101|Office Exp. - Computer Supplies|X
75102|Office Exp. - Office Supplies|X
75103|Office Exp. - Printing|X
75104|Office Exp. - Postage|X
75105|Office Exp. - Courier Service|X
75107|Office Exp. - Business Taxes|X
75108|Office Exp. - Coffee,Water,Etc|X
75109|Office Exp. - Automobile|X
75110|Office Exp. - Charitable|X
75111|Office Exp. - Bad Debts|X
75112|Office Exp. - Photocopies|X
75114|Office Exp. - Social|X
75115|Office Exp. - Recruiting|X
75116|Office Exp. - Conventions/Seminars|X
75117|Office Exp. - Entertainment|X
75118|Office Exp. - Software Subscription|X
75199|Office Exp. - Misc.|X
76101|Prof. Fees - Legal|X
76102|Prof. Fees - Accounting|X
76103|Prof. Fees - Consulting|X
79101|Depreciation|X
79102|Amortization - Franchise Fees|X
80001|Office Exp. - 100% Boker Expenses|X
80002|Office Exp. - Client Gifts|X
80101|Gain Or Loss On Fixed Assets|X
90101|Federal Income Taxes|T
90102|Provincial Income Taxes|T
`.trim();

const TYPE_MAP = {
  A: "ASSET",
  L: "LIABILITY",
  E: "EQUITY",
  S: "INCOME",
  O: "INCOME",
  C: "EXPENSE",
  X: "EXPENSE",
  T: "EXPENSE",
};

export const LEGACY_CHART_OF_ACCOUNTS = RAW.split("\n").map((line) => {
  const [code, name, legacyType] = line.split("|");
  return { code, name, legacyType, account_type: TYPE_MAP[legacyType] || "EXPENSE" };
});
