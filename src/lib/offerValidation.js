import { validateCommercialLeaseCommission } from "./commercialLeaseCommission";

const clean = value => String(value ?? "").replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
const norm = value => clean(value).toLowerCase().replace(/[^a-z0-9]/g, "");
const money = value => {
  const number = Number(String(value ?? "").replace(/[$,\s]/g, ""));
  return Number.isFinite(number) && number > 0 ? number : null;
};
const dateValue = value => {
  if (!value) return null;
  const date = new Date(String(value).slice(0, 10) + "T12:00:00");
  return Number.isNaN(date.getTime()) ? null : date;
};
const issue = (severity, code, title, detail, source = "") => ({ severity, code, title, detail, source });
const isCommercial = form => String(form?.market_segment || "").toUpperCase() === "COMMERCIAL";
const isLease = form => String(form?.transaction_type || "").toUpperCase() === "LEASE";
const partyNames = (list, fallback) => {
  const names = (Array.isArray(list) ? list : []).map(p => {
    if (String(p?.entity_type || "").toUpperCase() === "COMPANY") return clean(p.company_name);
    return clean([p?.first_name, p?.last_name].filter(Boolean).join(" "));
  }).filter(Boolean);
  return names.length ? names : (clean(fallback) ? [clean(fallback)] : []);
};

export function validateOfferPackage({ form = {}, docs = [], requirements = {}, requirementExceptions = [], documentTexts = [] } = {}) {
  const errors = [];
  const warnings = [];
  const passed = [];
  const add = (severity, code, title, detail, source) => {
    const item = issue(severity, code, title, detail, source);
    (severity === "error" ? errors : severity === "warning" ? warnings : passed).push(item);
  };
  const transaction = isLease(form) ? (isCommercial(form) ? "commercial lease" : "residential lease") : (isCommercial(form) ? "commercial purchase and sale" : "residential purchase and sale");
  const address = [form.street_number, form.street_name, form.unit_number ? "Unit " + form.unit_number : "", form.city, form.province, form.postal_code].filter(Boolean).join(" ");
  const propertyRequired = [["street_number", "Street number"], ["street_name", "Street name"], ["city", "City"], ["province", "Province"], ["postal_code", "Postal code"]];
  propertyRequired.forEach(([key, label]) => clean(form[key]) ? add("pass", "field_" + key, label + " entered", "The trade record contains this property detail.") : add("error", "field_" + key, "Missing " + label.toLowerCase(), "Enter the " + label.toLowerCase() + " before the offer package is finalized."));
  const buyers = partyNames(form.buyers, form.buyer_name);
  const sellers = partyNames(form.sellers, form.seller_name);
  if (!buyers.length) add("error", "buyer_missing", "Buyer / tenant name missing", "Enter the full legal name of every buyer or tenant.");
  else add("pass", "buyer_present", "Buyer / tenant details entered", buyers.join("; "));
  if (!sellers.length) add("error", "seller_missing", "Seller / landlord name missing", "Enter the full legal name of every seller or landlord.");
  else add("pass", "seller_present", "Seller / landlord details entered", sellers.join("; "));
  if (!clean(form.offer_date)) add("error", "offer_date_missing", "Offer date missing", "Enter the date the offer was prepared.");
  if (!clean(form.close_date)) add("error", "completion_date_missing", "Completion / possession date missing", "Enter the completion date or lease commencement date.");
  const offerDate = dateValue(form.offer_date);
  const closeDate = dateValue(form.close_date);
  if (offerDate && closeDate && closeDate < offerDate) add("error", "date_order", "Date sequence needs correction", "The completion or commencement date is earlier than the offer date.");
  else if (offerDate && closeDate) add("pass", "date_order", "Offer and completion dates checked", "The dates are in chronological order.");
  if (isLease(form)) {
    const rent = money(form.sale_price) || money(form.list_price);
    if (!rent && !form.commercial_lease_commission) add("error", "rent_missing", "Rent / lease value missing", "Enter the agreed rent or lease value in the trade details.");
    if (isCommercial(form) && form.commercial_lease_commission) {
      const commercialCheck = validateCommercialLeaseCommission(form.commercial_lease_commission);
      commercialCheck.errors.forEach((detail, index) => add("error", "commercial_lease_" + index, "Commercial lease details need correction", detail));
      commercialCheck.warnings.forEach((detail, index) => add("warning", "commercial_lease_warning_" + index, "Commercial lease review", detail));
    }
  } else {
    if (!money(form.sale_price)) add("error", "purchase_price_missing", "Purchase price missing", "Enter the agreed purchase price.");
    else add("pass", "purchase_price_present", "Purchase price entered", "The trade record contains a purchase price.");
  }
  if (!clean(form.acceptance_date)) add("warning", "acceptance_date_missing", "Acceptance date not entered", "Confirm the acceptance date when the offer has been accepted.");
  const representation = [form.buyer_representation_status, form.seller_representation_status];
  if (representation.some(value => !value || String(value).toUpperCase() === "UNKNOWN")) add("warning", "representation_unknown", "Representation status needs confirmation", "Confirm the representation status for both sides and complete any required self-represented-party disclosures.");
  const activeSide = String(form.side || "SELLER").toUpperCase();
  const rules = requirements?.[activeSide] || requirements?.[activeSide === "LANDLORD" ? "SELLER" : activeSide] || {};
  const configuredRequiredTypes = Array.isArray(rules.required) ? rules.required : (Array.isArray(rules.types) ? rules.types : []);
  const waivedTypes = new Set((requirementExceptions || []).filter(item => item?.requirement_waived !== false).map(item => String(item?.document_type || "").toUpperCase()));
  const requiredTypes = configuredRequiredTypes.filter(type => !waivedTypes.has(String(type).toUpperCase()));
  const counts = rules.counts || {};
  requiredTypes.forEach(type => {
    const count = Math.max(1, Number(counts[type] || 1));
    const matching = docs.filter(doc => String(doc.document_type || "").toUpperCase() === String(type).toUpperCase());
    if (matching.length < count) add("error", "document_missing_" + type, "Required document missing", (matching.length ? "Upload " + (count - matching.length) + " more " : "Upload ") + (String(type).toUpperCase() === "APS" ? "offer / agreement form" : (type + " document")) + ".");
    else add("pass", "document_present_" + type, "Required document uploaded", type + " (" + matching.length + " uploaded).");
  });
  const pending = docs.filter(doc => !["MATCH", "APPROVED"].includes(String(doc.match_status || "PENDING").toUpperCase()));
  if (pending.length) add("warning", "documents_pending_review", "Documents still need brokerage review", pending.length + " uploaded document(s) have not been approved by Trade Admin. This is separate from the automated offer checks.");
  if (!docs.length) add("error", "no_documents", "No documents uploaded", "Upload the offer form and the supporting listing documents.");
  const texts = (documentTexts || []).filter(item => clean(item.text)).map(item => ({...item, text: clean(item.text)}));
  const aps = texts.find(item => String(item.document_type || "").toUpperCase() === "APS") || texts.find(item => /agreement of purchase and sale|agreement to lease|ore[a]?\s*(?:form\s*)?(?:100|400)/i.test(item.text));
  if (!aps) {
    if (docs.some(doc => String(doc.document_type || "").toUpperCase() === "APS")) add("warning", "aps_text_unavailable", "Offer form could not be read automatically", "The offer form is attached, but its text could not be extracted. Review the original PDF manually.");
    else add("error", "aps_missing", "Offer form not identified", "Upload the applicable agreement form and label it as the Agreement of Purchase and Sale / Lease.");
  } else {
    const text = aps.text;
    const leaseMarker = /commercial lease|lease agreement|agreement to lease|offer to lease|tenant|landlord/i.test(text);
    const saleMarker = /agreement of purchase and sale|purchase price|buyer|seller/i.test(text);
    if (isLease(form) && !leaseMarker) add("warning", "form_type_mismatch", "Uploaded form may not be a lease", "The trade is recorded as a lease, but the extracted form text does not clearly identify a lease agreement.", aps.name);
    else if (!isLease(form) && !saleMarker) add("warning", "form_type_mismatch", "Uploaded form may not be a purchase agreement", "The trade is recorded as a purchase and sale, but the extracted form text does not clearly identify an APS.", aps.name);
    else add("pass", "form_type_match", "Offer form type checked", "The uploaded form appears consistent with the transaction type.", aps.name);
    const upper = text.toUpperCase();
    const schedules = [...upper.matchAll(/\bSCHEDULE\s+([A-Z0-9]+)\b/g)].map(match => match[1]);
    [...new Set(schedules)].forEach(schedule => {
      const attached = texts.some(item => item !== aps && new RegExp("\\bSCHEDULE\\s+" + schedule + "\\b", "i").test(item.text)) ||
        docs.some(doc => doc !== aps && new RegExp("schedule\\s+" + schedule, "i").test(String(doc.document_name || "")));
      if (!attached) add("error", "schedule_missing_" + schedule, "Referenced Schedule " + schedule + " not found", "The offer form refers to Schedule " + schedule + ", but no matching uploaded document was identified.", aps.name);
    });
    const textAddress = text.match(/\b(?:PROPERTY\s+ADDRESS|MUNICIPAL\s+ADDRESS|ADDRESS)\s*:?\s*([^\n]{8,120})/i)?.[1] || "";
    if (textAddress && address && norm(textAddress).length > 8 && !norm(textAddress).includes(norm(form.street_number)) && !norm(textAddress).includes(norm(form.street_name).slice(0, 8))) {
      add("warning", "property_address_mismatch", "Property address may not match", "The address extracted from the offer form differs from the trade record. Compare both documents.", aps.name);
    } else if (textAddress) add("pass", "property_address_checked", "Property address compared", "No obvious address mismatch was detected.", aps.name);
    const priceText = text.match(/(?:PURCHASE\s+PRICE|PRICE)\s*[:\-]?\s*\$?\s*([0-9][0-9,]*(?:\.\d{2})?)/i)?.[1];
    const documentPrice = money(priceText);
    const tradePrice = money(form.sale_price);
    if (documentPrice && tradePrice && Math.abs(documentPrice - tradePrice) > 1) add("error", "price_mismatch", "Purchase price does not match", "Offer form shows $" + documentPrice.toLocaleString("en-CA") + " while the trade record shows $" + tradePrice.toLocaleString("en-CA") + ".", aps.name);
    else if (documentPrice && tradePrice) add("pass", "price_match", "Purchase price compared", "The purchase price in the offer form matches the trade record.", aps.name);
    if (/initials|signature|signed by|date signed/i.test(text)) add("warning", "signature_visual_review", "Initials and signatures need visual review", "Text extraction cannot confirm that signature, initials, or date fields are actually completed. Inspect every signature page before sending for signatures.", aps.name);
  }
  const nonReadable = docs.filter(doc => !/pdf/i.test(String(doc.mime_type || "")) && !/\.(pdf)$/i.test(String(doc.document_name || "")));
  if (nonReadable.length) add("warning", "non_pdf_review", "Some documents need manual review", nonReadable.length + " non-PDF file(s) were not included in text comparison.");
  const unique = list => list.filter((item, index) => list.findIndex(other => other.code === item.code) === index);
  return { transaction, checkedAt: new Date().toISOString(), errors: unique(errors), warnings: unique(warnings), passed: unique(passed), canProceed: errors.length === 0, total: errors.length + warnings.length + passed.length };
}


/**
 * Post-signature check is limited to the client represented by this brokerage.
 * Actual handwritten signatures cannot be authenticated by text extraction;
 * each client's signature, initials and date must be visually confirmed.
 */
export function validateOfferPostSignature({ form = {}, docs = [], clientConfirmations = {} } = {}) {
  const errors = [];
  const warnings = [];
  const passed = [];
  const side = String(form.side || "").toUpperCase();
  const clientSide = ["BUYER", "TENANT"].includes(side) ? "BUYER" : "SELLER";
  const partyList = clientSide === "BUYER" ? form.buyers : form.sellers;
  const fallback = clientSide === "BUYER" ? form.buyer_name : form.seller_name;
  const clients = (Array.isArray(partyList) ? partyList : []).map((party, index) => {
    const company = String(party?.entity_type || "").toUpperCase() === "COMPANY" || Boolean(party?.company_name);
    const name = company
      ? clean(party.company_name)
      : clean([party?.first_name, party?.last_name].filter(Boolean).join(" "));
    const representatives = (party?.representatives || []).map(rep => clean([rep?.first_name, rep?.last_name].filter(Boolean).join(" "))).filter(Boolean);
    return { id: clientSide.toLowerCase() + "_" + index, name: name || (clientSide === "BUYER" ? "Buyer " : "Seller ") + (index + 1), company, representatives };
  }).filter(Boolean);
  if (!clients.length && clean(fallback)) clients.push({ id: clientSide.toLowerCase() + "_0", name: clean(fallback), company: false, representatives: [] });
  if (!clients.length) errors.push(issue("error", "post_client_missing", "Our client is not identified", "Complete the represented buyer/tenant or seller/landlord details before the post-signature check."));
  const signedAgreement = docs.filter(doc => String(doc.document_type || "").toUpperCase() === "APS");
  if (!signedAgreement.length) errors.push(issue("error", "post_signed_agreement_missing", "Signed agreement not uploaded", "Upload the signed agreement under the APS document type before running the post-signature check."));
  else passed.push(issue("pass", "post_signed_agreement_present", "Agreement uploaded", signedAgreement.length + " agreement document(s) attached. Confirm that the correct fully signed version is selected."));
  clients.forEach(client => {
    if (clientConfirmations[client.id] === true) {
      passed.push(issue("pass", "client_signoff_" + client.id, "Client signature review confirmed", client.name + ": signature, required initials and signing date visually checked."));
    } else {
      errors.push(issue("error", "client_signoff_" + client.id, "Client signature review not confirmed", "Open the signed agreement and visually confirm " + client.name + " has signed, completed all required initials and dates."));
    }
  });
  warnings.push(issue("warning", "other_party_not_checked", "Other party signatures are outside this check", "This post-check covers only our represented client(s). It does not require or verify the other party's signatures."));
  warnings.push(issue("warning", "manual_visual_review", "Visual review is required", "Automated checks cannot authenticate handwritten signatures or reliably determine whether every signature, initial and date field is complete. The confirmations above must be made after inspecting the original signed document."));
  return { stage: "POST_SIGNATURE", clientSide, clients, checkedAt: new Date().toISOString(), errors, warnings, passed, canProceed: errors.length === 0, total: errors.length + warnings.length + passed.length };
}
