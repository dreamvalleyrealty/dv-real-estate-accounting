// CRA 2026 Ontario payroll calculations based on CRA T4127 (123rd edition, July 1, 2026).
// This module handles regular periodic payroll for Ontario employees.
// Bonuses, commissions, taxable benefits, garnishments and special CPP/EI cases require separate CRA treatment.
export const PAY_PERIODS={WEEKLY:52,BIWEEKLY:26,SEMI_MONTHLY:24,MONTHLY:12};

const FEDERAL_CLAIMS={
  0:0,1:16452,2:17868.50,3:20701.50,4:23534.50,5:26367.50,
  6:29200.50,7:32033.50,8:34866.50,9:37699.50,10:40532.50
};
const ONTARIO_CLAIMS={
  0:0,1:12989,2:14388,3:17186,4:19984,5:22782,
  6:25580,7:28378,8:31176,9:33974,10:36772
};
const FED_RATES=[{limit:58523,r:.14,k:0},{limit:117045,r:.205,k:3804},{limit:181440,r:.26,k:10241},{limit:258482,r:.29,k:15685},{limit:Infinity,r:.33,k:26024}];
const ON_RATES=[{limit:53891,r:.0505,k:0},{limit:107785,r:.0915,k:2210},{limit:150000,r:.1116,k:4376},{limit:220000,r:.1216,k:5876},{limit:Infinity,r:.1316,k:8076}];

const n=v=>Number(v||0);
const round2=v=>Math.round((n(v)+Number.EPSILON)*100)/100;
const annualTax=(a,rates)=>{const x=Math.max(0,n(a));for(const b of rates){if(x<=b.limit)return Math.max(0,b.r*x-b.k)}return 0};
const clamp=(v,min=0,max=Infinity)=>Math.min(max,Math.max(min,n(v)));

export function claimAmount(code,type){
  const c=Number(code||1);
  return type==="ON"? (ONTARIO_CLAIMS[c]??ONTARIO_CLAIMS[1]) : (FEDERAL_CLAIMS[c]??FEDERAL_CLAIMS[1]);
}

export function calculateOntarioPayroll({
  gross=0,
  ytdGross=0,
  ytdCpp=0,
  ytdCpp2=0,
  ytdEi=0,
  ytdTax=0,
  payFrequency="BIWEEKLY",
  payPeriodsCompleted=0,
  federalClaimCode=1,
  ontarioClaimCode=1,
  additionalTax=0,
  cppExempt=false,
  eiExempt=false
}={}){
  const P=PAY_PERIODS[payFrequency]||26;
  const periodNumber=Math.max(1,n(payPeriodsCompleted)+1);
  const S1=P/periodNumber;
  const G=round2(gross);
  const Y=n(ytdGross);
  const PE=Y+G;
  const baseExemption=3500/P;

  const cpp=cppExempt?0:round2(clamp(Math.min(4230.45-n(ytdCpp),0.0595*Math.max(0,G-baseExemption))));
  const cpp2=cppExempt?0:round2(clamp(Math.min(416-n(ytdCpp2),0.04*Math.max(0,PE-Math.max(Y,74600)))));
  const ei=eiExempt?0:round2(clamp(Math.min(1123.07-n(ytdEi),0.0163*G)));
  const employerCpp=cpp;
  const employerCpp2=cpp2;
  const employerEi=round2(Math.min(1572.30-n(ytdEi*1.4),ei*1.4));

  // F5/F5A: first additional CPP plus CPP2 are deductible in the annual taxable-income calculation.
  const additionalCpp=round2(cpp*(0.01/0.0595)+cpp2);
  const ytdAdditionalCpp=round2(n(ytdCpp)*(0.01/0.0595)+n(ytdCpp2));
  const A=Math.max(0,S1*(PE-additionalCpp-ytdAdditionalCpp));

  const tc=claimAmount(federalClaimCode,"FED");
  const tcp=claimAmount(ontarioClaimCode,"ON");

  const baseCppCredit=Math.min(3519.45,Math.max(0,0.0495*(S1*PE-3500)));
  const eiCredit=Math.min(1123.07,Math.max(0,0.0163*S1*PE));
  const k1=0.14*tc;
  const k2=0.14*(baseCppCredit+eiCredit);
  const k4=0.14*Math.min(A,1501);
  const t3=Math.max(0,annualTax(A,FED_RATES)-k1-k2-k4);

  const kpOn=0;
  const k1p=0.0505*tcp;
  const baseCppCreditOn=Math.min(3519.45,Math.max(0,0.0495*(S1*PE-3500)));
  const eiCreditOn=Math.min(1123.07,Math.max(0,0.0163*S1*PE));
  const k2p=0.0505*(baseCppCreditOn+eiCreditOn);
  const t4=Math.max(0,annualTax(A,ON_RATES)-kpOn-k1p-k2p);

  let v1=0;
  if(t4>5818&&t4<=7446)v1=0.20*(t4-5818);
  else if(t4>7446)v1=(0.20*(t4-5818))+(0.36*(t4-7446));

  let v2=0;
  if(A>200000)v2=Math.min(900,750+0.25*(A-200000));
  else if(A>72000)v2=Math.min(750,600+0.25*(A-72000));
  else if(A>48000)v2=Math.min(600,450+0.25*(A-48000));
  else if(A>36000)v2=Math.min(450,300+0.06*(A-36000));
  else if(A>20000)v2=Math.min(300,0.06*(A-20000));

  const S=Math.max(0,Math.min(t4+v1,2*300-(t4+v1)));
  const annualTaxPayable=Math.max(0,t3+t4+v1+v2-S);
  const tax=round2(Math.max(0,((annualTaxPayable/S1)-n(ytdTax))+n(additionalTax)));
  const netPay=round2(G-cpp-cpp2-ei-tax);

  return {
    gross_pay:G,income_tax:tax,cpp,cpp2,ei,employer_cpp:employerCpp,
    employer_cpp2:employerCpp2,employer_ei:employerEi,net_pay:netPay,
    annual_taxable_income:round2(A),pay_periods:P,pay_period_number:periodNumber,
    additional_cpp_deduction:additionalCpp,annual_federal_tax:round2(t3),
    annual_ontario_tax:round2(Math.max(0,t4+v1+v2-S))
  };
}
