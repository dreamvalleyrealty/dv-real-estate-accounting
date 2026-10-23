/**
 * Commercial lease commission calculation engine.
 *
 * The signed commission agreement is authoritative. This module intentionally
 * does not infer the rent base, NET meaning, HST treatment, or payment trigger.
 * All money is rounded to cents at the line-item level.
 */

const roundMoney = value => Math.round((Number(value) + Number.EPSILON) * 100) / 100;
const isFiniteNumber = value => value !== null && value !== "" && Number.isFinite(Number(value));

export const COMMISSION_BASES = [
  { value: "BASE_RENT", label: "Base rent" },
  { value: "GROSS_RENT", label: "Gross rent" },
  { value: "BASE_AND_ADDITIONAL_RENT", label: "Base rent plus specified additional rent" },
  { value: "FIXED_AMOUNT", label: "Fixed amount" },
  { value: "PER_SQUARE_FOOT", label: "Amount per square foot" },
  { value: "MONTHS_OF_RENT", label: "Specified months of rent" },
  { value: "CUSTOM", label: "Custom agreement formula" },
];

export const NET_TREATMENTS = [
  { value: "GROSS_COMMISSION", label: "Gross commission before brokerage deductions" },
  { value: "LESS_SPECIFIED_DEDUCTIONS", label: "Net after specified deductions" },
  { value: "NET_PAYABLE_TO_COOPERATING_BROKERAGE", label: "Net payable to cooperating brokerage" },
  { value: "OTHER_DEFINED", label: "Other defined meaning" },
  { value: "UNRESOLVED", label: "Unclear / needs administrator review" },
];

export const HST_TREATMENTS = [
  { value: "ADDED", label: "HST added to commission" },
  { value: "INCLUDED", label: "HST included in commission amount" },
  { value: "NOT_APPLICABLE", label: "Not applicable (requires explanation)" },
  { value: "UNRESOLVED", label: "Unclear / needs administrator review" },
];

/**
 * rentSchedule rows:
 * { periodLabel, startDate, endDate, months, baseRent, additionalRent,
 *   grossRent, rentFrequency: "MONTHLY"|"ANNUAL", escalationType,
 *   escalationValue }
 *
 * commissionSchedule rows:
 * { periodLabel, startPeriod, endPeriod, ratePercent, fixedAmount,
 *   base, netTreatment, netDefinition, hstTreatment, hstRatePercent,
 *   deductions, paymentTrigger }
 *
 * Period matching is explicit. startPeriod/endPeriod are 1-based lease years.
 */
export function validateCommercialLeaseCommission(input = {}) {
  const errors = [];
  const warnings = [];
  const leaseTermMonths = Number(input.leaseTermMonths);
  const rentSchedule = Array.isArray(input.rentSchedule) ? input.rentSchedule : [];
  const commissionSchedule = Array.isArray(input.commissionSchedule) ? input.commissionSchedule : [];
  const supportedBases = new Set(COMMISSION_BASES.map(x => x.value));

  if (!Number.isInteger(leaseTermMonths) || leaseTermMonths < 1 || leaseTermMonths > 1200) {
    errors.push("Enter a valid lease term in months.");
  }
  if (!rentSchedule.length) errors.push("Add a rent schedule covering the lease term.");
  if (!commissionSchedule.length) errors.push("Add at least one commission schedule row.");

  const rentYears = new Set();
  rentSchedule.forEach((row, index) => {
    const label = row.periodLabel || `Rent row ${index + 1}`;
    const start = Number(row.startPeriod);
    const end = Number(row.endPeriod);
    if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) {
      errors.push(`${label}: enter a valid start and end lease period.`);
    } else {
      for (let year = start; year <= end; year++) {
        if (rentYears.has(year)) errors.push(`${label}: overlaps another rent period (year ${year}).`);
        rentYears.add(year);
      }
    }
    if (!isFiniteNumber(row.baseRent) || Number(row.baseRent) < 0) {
      errors.push(`${label}: base rent must be zero or greater.`);
    }
    if (row.additionalRent !== undefined && (!isFiniteNumber(row.additionalRent) || Number(row.additionalRent) < 0)) {
      errors.push(`${label}: additional rent must be zero or greater.`);
    }
    if (row.escalationType === "PERCENT" && (!isFiniteNumber(row.escalationValue) || Number(row.escalationValue) < 0)) {
      errors.push(`${label}: enter a valid rent escalation percentage.`);
    }
    if (row.escalationType === "FIXED" && (!isFiniteNumber(row.escalationValue) || Number(row.escalationValue) < 0)) {
      errors.push(`${label}: enter a valid fixed rent increase.`);
    }
  });

  if (Number.isInteger(leaseTermMonths) && leaseTermMonths > 0) {
    const yearsNeeded = Math.ceil(leaseTermMonths / 12);
    for (let year = 1; year <= yearsNeeded; year++) {
      if (!rentYears.has(year)) errors.push(`Rent schedule does not cover lease year ${year}.`);
    }
    for (const year of rentYears) {
      if (year > yearsNeeded) errors.push(`Rent schedule includes lease year ${year}, beyond the lease term.`);
    }
  }

  const commissionYears = new Set();
  commissionSchedule.forEach((row, index) => {
    const label = row.periodLabel || `Commission row ${index + 1}`;
    const start = Number(row.startPeriod);
    const end = Number(row.endPeriod);
    if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) {
      errors.push(`${label}: enter a valid start and end lease period.`);
    } else {
      for (let year = start; year <= end; year++) {
        if (commissionYears.has(year)) errors.push(`${label}: overlaps another commission period (year ${year}).`);
        commissionYears.add(year);
      }
    }
    if (!supportedBases.has(row.base)) errors.push(`${label}: select a defined commission calculation basis.`);
    if (row.base === "FIXED_AMOUNT" && (!isFiniteNumber(row.fixedAmount) || Number(row.fixedAmount) < 0)) {
      errors.push(`${label}: enter a valid fixed commission amount.`);
    }
    if (row.base === "PER_SQUARE_FOOT" && (!isFiniteNumber(row.fixedAmount) || Number(row.fixedAmount) < 0 || !isFiniteNumber(input.squareFeet) || Number(input.squareFeet) <= 0)) {
      errors.push(`${label}: enter a valid amount per square foot and leased area.`);
    }
    if (row.base === "MONTHS_OF_RENT" && (!isFiniteNumber(row.monthsOfRent) || Number(row.monthsOfRent) < 0)) {
      errors.push(`${label}: enter the agreed number of months of rent.`);
    }
    if (["BASE_RENT", "GROSS_RENT", "BASE_AND_ADDITIONAL_RENT"].includes(row.base) &&
        (!isFiniteNumber(row.ratePercent) || Number(row.ratePercent) < 0 || Number(row.ratePercent) > 100)) {
      errors.push(`${label}: enter a commission percentage from 0 to 100.`);
    }
    if (row.base === "CUSTOM" && !String(row.customFormulaDescription || "").trim()) {
      errors.push(`${label}: describe the custom formula from the signed agreement.`);
    }
    if (!row.netTreatment || row.netTreatment === "UNRESOLVED") {
      errors.push(`${label}: NET treatment is unresolved and requires administrator review.`);
    }
    if (["LESS_SPECIFIED_DEDUCTIONS", "OTHER_DEFINED"].includes(row.netTreatment) && !String(row.netDefinition || "").trim()) {
      errors.push(`${label}: define the NET treatment before submission.`);
    }
    if (!row.hstTreatment || row.hstTreatment === "UNRESOLVED") {
      errors.push(`${label}: HST treatment is unresolved and requires administrator review.`);
    }
    if (row.hstTreatment === "NOT_APPLICABLE" && !String(row.hstExemptionReason || "").trim()) {
      errors.push(`${label}: explain why HST is not applicable.`);
    }
    if (row.hstTreatment !== "NOT_APPLICABLE" &&
        (!isFiniteNumber(row.hstRatePercent) || Number(row.hstRatePercent) < 0 || Number(row.hstRatePercent) > 100)) {
      errors.push(`${label}: enter a valid HST rate.`);
    }
    if (row.paymentTrigger === "CUSTOM" && !String(row.paymentTriggerDescription || "").trim()) {
      errors.push(`${label}: describe the commission payment trigger.`);
    }
    if (row.base === "CUSTOM") warnings.push(`${label}: custom formulas must be checked by an administrator against the signed agreement.`);
  });

  if (Number.isInteger(leaseTermMonths) && leaseTermMonths > 0) {
    const yearsNeeded = Math.ceil(leaseTermMonths / 12);
    for (let year = 1; year <= yearsNeeded; year++) {
      if (!commissionYears.has(year)) errors.push(`Commission schedule does not cover lease year ${year}.`);
    }
    for (const year of commissionYears) {
      if (year > yearsNeeded) errors.push(`Commission schedule includes lease year ${year}, beyond the lease term.`);
    }
  }

  if (!input.signedAgreementDocumentId) {
    warnings.push("Attach the signed commission agreement or signed lease clause that establishes the commission.");
  }
  if (!input.commissionAuthorityConfirmed) {
    warnings.push("Administrator must confirm the uploaded signed agreement is the controlling commission authority.");
  }

  return { valid: errors.length === 0, errors, warnings, requiresAdminReview: errors.length > 0 || warnings.length > 0 };
}

/**
 * Calculates only when the supplied inputs are valid. The caller must first
 * translate the agreement's rent language into explicit annual rent values.
 * This avoids silently deciding whether free rent, TMI/additional rent, or
 * partial-year rules are included.
 */
export function calculateCommercialLeaseCommission(input = {}) {
  const validation = validateCommercialLeaseCommission(input);
  if (!validation.valid) return { ...validation, lines: [], subtotal: null, hst: null, total: null };

  const rentByYear = new Map();
  for (const row of input.rentSchedule) {
    for (let year = Number(row.startPeriod); year <= Number(row.endPeriod); year++) {
      let baseRent = Number(row.baseRent);
      let additionalRent = Number(row.additionalRent || 0);
      const prior = rentByYear.get(year - 1);
      if (row.escalationType === "PERCENT" && year > Number(row.startPeriod)) {
        baseRent = roundMoney(baseRent * Math.pow(1 + Number(row.escalationValue) / 100, year - Number(row.startPeriod)));
        additionalRent = roundMoney(additionalRent * Math.pow(1 + Number(row.additionalEscalationPercent || 0) / 100, year - Number(row.startPeriod)));
      } else if (row.escalationType === "FIXED" && year > Number(row.startPeriod)) {
        baseRent = roundMoney(baseRent + Number(row.escalationValue) * (year - Number(row.startPeriod)));
      } else if (row.escalationType === "CARRY_FORWARD" && prior) {
        baseRent = prior.baseRent;
        additionalRent = prior.additionalRent;
      }
      if (year === Math.ceil(Number(input.leaseTermMonths) / 12) && Number(input.leaseTermMonths) % 12) {
        const fraction = (Number(input.leaseTermMonths) % 12) / 12;
        baseRent = roundMoney(baseRent * fraction);
        additionalRent = roundMoney(additionalRent * fraction);
      }
      rentByYear.set(year, { baseRent, additionalRent, grossRent: roundMoney(baseRent + additionalRent) });
    }
  }

  const leaseTermValue = roundMoney([...rentByYear.values()].reduce((sum, rent) => sum + rent.grossRent, 0));
  const lines = [];
  for (const row of input.commissionSchedule) {
    for (let year = Number(row.startPeriod); year <= Number(row.endPeriod); year++) {
      const rent = rentByYear.get(year);
      let basisAmount;
      if (row.base === "BASE_RENT") basisAmount = rent.baseRent;
      else if (row.base === "GROSS_RENT") basisAmount = rent.grossRent;
      else if (row.base === "BASE_AND_ADDITIONAL_RENT") basisAmount = rent.grossRent;
      else if (row.base === "FIXED_AMOUNT") basisAmount = Number(row.fixedAmount) / (Number(row.endPeriod) - Number(row.startPeriod) + 1);
      else if (row.base === "PER_SQUARE_FOOT") basisAmount = Number(row.fixedAmount) * Number(input.squareFeet);
      else if (row.base === "MONTHS_OF_RENT") basisAmount = (rent.baseRent / 12) * Number(row.monthsOfRent);
      else basisAmount = null;

      if (basisAmount === null) {
        return { valid: false, errors: [`${row.periodLabel || "Commission row"}: custom formula requires an approved manual calculation.`], warnings: validation.warnings, requiresAdminReview: true, lines: [], subtotal: null, hst: null, total: null };
      }

      let grossCommission = row.base === "FIXED_AMOUNT" || row.base === "PER_SQUARE_FOOT" || row.base === "MONTHS_OF_RENT"
        ? roundMoney(basisAmount)
        : roundMoney(basisAmount * Number(row.ratePercent) / 100);
      const deductions = roundMoney(Number(row.deductions || 0));
      if (row.netTreatment === "LESS_SPECIFIED_DEDUCTIONS") grossCommission = roundMoney(grossCommission - deductions);
      if (row.netTreatment === "NET_PAYABLE_TO_COOPERATING_BROKERAGE") {
        if (!isFiniteNumber(row.netPayableAmount) || Number(row.netPayableAmount) < 0) {
          return { valid: false, errors: [`${row.periodLabel || "Commission row"}: enter the agreed net payable amount or have an administrator define the formula.`], warnings: validation.warnings, requiresAdminReview: true, lines: [], subtotal: null, hst: null, total: null };
        }
        grossCommission = roundMoney(Number(row.netPayableAmount));
      }
      if (grossCommission < 0) {
        return { valid: false, errors: [`${row.periodLabel || "Commission row"}: deductions exceed commission.`], warnings: validation.warnings, requiresAdminReview: true, lines: [], subtotal: null, hst: null, total: null };
      }
      const hst = row.hstTreatment === "ADDED" ? roundMoney(grossCommission * Number(row.hstRatePercent) / 100) : 0;
      const commissionExcludingHst = row.hstTreatment === "INCLUDED"
        ? roundMoney(grossCommission / (1 + Number(row.hstRatePercent) / 100))
        : grossCommission;
      const includedHst = row.hstTreatment === "INCLUDED" ? roundMoney(grossCommission - commissionExcludingHst) : 0;
      lines.push({
        periodLabel: row.periodLabel || `Lease year ${year}`,
        leaseYear: year,
        rentBase: roundMoney(basisAmount),
        commissionRatePercent: row.ratePercent == null ? null : Number(row.ratePercent),
        commissionBeforeHst: commissionExcludingHst,
        hst: roundMoney(hst + includedHst),
        totalCommission: roundMoney(commissionExcludingHst + hst + includedHst),
        netTreatment: row.netTreatment,
        hstTreatment: row.hstTreatment,
        paymentTrigger: row.paymentTrigger || null,
      });
    }
  }
  const subtotal = roundMoney(lines.reduce((sum, line) => sum + line.commissionBeforeHst, 0));
  const hst = roundMoney(lines.reduce((sum, line) => sum + line.hst, 0));
  const total = roundMoney(lines.reduce((sum, line) => sum + line.totalCommission, 0));
  return { valid: true, errors: [], warnings: validation.warnings, requiresAdminReview: validation.requiresAdminReview, lines, subtotal, hst, total, leaseTermValue };
}
