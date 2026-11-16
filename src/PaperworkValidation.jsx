import { useEffect, useState } from "react";
import { AlertCircle, FileCheck2, FileText, RefreshCw, Trash2, Upload } from "lucide-react";
import { supabase } from "./lib/supabase";

const TYPES = [["FORM","Form / Agreement"],["SCHEDULE","Schedule / Attachment"],["DISCLOSURE","Disclosure"],["ID","Identity Document"],["OTHER","Other"]];
const isPdf = file => /pdf/i.test(file?.type || "") || /\\.pdf$/i.test(file?.name || "");
const idFor = () => typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random();
const hasValue = value => value !== undefined && value !== null && String(value).trim() !== "" && String(value).trim() !== "Off";
const normalize = value => String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
const postSignatureRules = rules => (Array.isArray(rules) ? rules : []).filter(rule =>
  rule.required !== false && ["POST_SIGN","BOTH"].includes(String(rule.stage || "PRE_SIGN").toUpperCase()) &&
  ["SIGNATURE","INITIAL","DATE"].includes(String(rule.kind || "").toUpperCase())
);
const result = (code,title,detail) => ({ code,title,detail });

export default function PaperworkValidation({ isActive = true }) {
  const [files, setFiles] = useState([]);
  const [analyses, setAnalyses] = useState({});
  const [libraryForms, setLibraryForms] = useState([]);
  const [libraryError, setLibraryError] = useState("");
  const [reports, setReports] = useState({ pre: null, post: null });
  const [signatureChecks, setSignatureChecks] = useState({});
  const [showPostReview, setShowPostReview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    let live = true;
    async function loadLibrary() {
      if (!supabase) return;
      const { data, error: queryError } = await supabase.from("dv_accounting_paperwork_library")
        .select("id,document_name,category,version,effective_date,validation_rules")
        .eq("status","PUBLISHED").order("document_name",{ascending:true}).order("created_at",{ascending:false});
      if (!live) return;
      if (queryError) setLibraryError(queryError.message);
      else setLibraryForms(data || []);
    }
    loadLibrary();
    return () => { live = false; };
  }, []);

  function resetValidation() {
    setFiles([]);
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
    setShowPostReview(false);
    setError("");
    setMessage("");
  }
  useEffect(() => { if (!isActive) resetValidation(); }, [isActive]);

  function addFiles(list) {
    const picked = Array.from(list || []);
    if (!picked.length) return;
    setFiles(current => [...current, ...picked.map(file => ({ id: idFor(), file, type: "FORM", referenceId: "" }))]);
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
    setShowPostReview(false);
    setError("");
    setMessage("");
  }

  async function analyzePdf(file) {
    const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
    const workerUrl = (await import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url")).default;
    pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    const pages = [];
    let ocrWorker = null;
    try {
      for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
        const page = await pdf.getPage(pageNumber);
        const content = await page.getTextContent();
        let text = (content.items || []).map(item => String(item.str || "").trim()).filter(Boolean).join(" ");
        const annotations = await page.getAnnotations({ intent: "display" });
        const fields = annotations.filter(item => item.subtype === "Widget").map(item => ({
          name: item.fieldName || item.alternativeText || "Unnamed field",
          type: item.fieldType || "Text",
          value: item.fieldValue,
          required: Boolean((Number(item.fieldFlags) || 0) & 2)
        }));
        if (text.trim().length < 30) {
          if (!ocrWorker) {
            const { createWorker } = await import("tesseract.js");
            ocrWorker = await createWorker("eng");
          }
          const viewport = page.getViewport({ scale: 1.5 });
          const canvas = document.createElement("canvas");
          canvas.width = Math.ceil(viewport.width);
          canvas.height = Math.ceil(viewport.height);
          await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise;
          const scanned = await ocrWorker.recognize(canvas);
          const ocrText = String(scanned?.data?.text || "");
          if (ocrText.trim().length > text.trim().length) text = ocrText;
          canvas.width = 0;
          canvas.height = 0;
        }
        pages.push({ pageNumber, text, fields, hasText: text.trim().length > 0 });
      }
    } finally {
      if (ocrWorker) await ocrWorker.terminate();
      pdf.destroy();
    }
    return pages;
  }

  async function analyzeImage(file) {
    const { createWorker } = await import("tesseract.js");
    const worker = await createWorker("eng");
    try {
      const scanned = await worker.recognize(file);
      const text = String(scanned?.data?.text || "");
      return [{ pageNumber: 1, text, fields: [], hasText: Boolean(text.trim()) }];
    } finally { await worker.terminate(); }
  }

  async function runPreCheck() {
    if (!files.length) { setError("Upload one or more forms first."); return; }
    setBusy(true);
    setError("");
    setMessage("");
    setReports({ pre: null, post: null });
    try {
      const next = {};
      for (const item of files) {
        let pages = [];
        try {
          if (isPdf(item.file)) pages = await analyzePdf(item.file);
          else if (/^image\\//i.test(item.file.type) || /\\.(png|jpe?g|tiff?)$/i.test(item.file.name)) pages = await analyzeImage(item.file);
          else pages = [{ pageNumber: 1, text: "", fields: [], hasText: false, unsupported: true }];
        } catch (e) {
          pages = [{ pageNumber: 1, text: "", fields: [], hasText: false, unreadable: true, error: e?.message || "Could not read this file" }];
        }
        next[item.id] = pages;
      }
      setAnalyses(next);

      const errors = [];
      const warnings = [];
      const passed = [];
      files.forEach(item => {
        const pages = next[item.id] || [];
        const fileName = item.file.name;
        const fields = pages.flatMap(page => page.fields.map(field => ({ ...field, pageNumber: page.pageNumber })));
        if (!pages.length || pages.every(page => !page.hasText && !page.fields.length)) {
          warnings.push(result(item.id + "_manual",fileName + ": manual review required","No readable form fields or text were detected. Open the original and inspect every page."));
        }
        let requiredCount = 0;
        let blankRequired = 0;
        pages.forEach(page => {
          page.fields.filter(field => field.required && !["Sig"].includes(field.type)).forEach(field => {
            requiredCount++;
            if (!hasValue(field.value)) {
              blankRequired++;
              errors.push(result(item.id + "_" + page.pageNumber + "_" + field.name,fileName + " — page " + page.pageNumber + ": " + field.name + " is blank","This PDF field is marked as required and has no entered value."));
            }
          });
          page.fields.filter(field => field.type === "Sig" && !hasValue(field.value)).forEach(field =>
            warnings.push(result(item.id + "_sig_" + page.pageNumber + "_" + field.name,fileName + " — page " + page.pageNumber + ": signature field is empty","A digital signature field appears blank. Confirm whether this form is expected to be signed at this stage."))
          );
          if (!page.hasText && !page.fields.length) warnings.push(result(item.id + "_page_" + page.pageNumber,fileName + " — page " + page.pageNumber + " needs visual review","The system could not read this page. Check it for blank required sections, checkboxes and missing entries."));
        });
        if (requiredCount && blankRequired === 0) passed.push(result(item.id + "_required",fileName + ": required PDF fields completed",requiredCount + " required fillable field(s) contain values."));
        if (!requiredCount) warnings.push(result(item.id + "_no_required",fileName + ": manual completion review needed","This form has no machine-readable required fields. Use the reference checklist below and inspect the original page by page."));
        if (pages.some(page => page.fields.some(field => field.type === "Btn"))) warnings.push(result(item.id + "_checkbox",fileName + ": review checkboxes and selections","Confirm that every applicable checkbox, option and declaration has been selected. Unselected options may be intentional."));

        const reference = libraryForms.find(form => form.id === item.referenceId);
        if (reference) {
          const rules = Array.isArray(reference.validation_rules) ? reference.validation_rules : [];
          const preRules = rules.filter(rule => rule.required !== false && ["PRE_SIGN","BOTH"].includes(String(rule.stage || "PRE_SIGN").toUpperCase()) && !["SIGNATURE","INITIAL"].includes(String(rule.kind || "").toUpperCase()));
          if (!preRules.length) warnings.push(result(item.id + "_no_rules",fileName + ": no pre-signature rules configured","The selected library version has no pre-signature completion rules yet."));
          preRules.forEach((rule,index) => {
            const targetPage = Number(rule.page) > 0 ? Number(rule.page) : null;
            const key = normalize(rule.field_key || rule.label);
            const matched = fields.filter(field => {
              const fieldKey = normalize(field.name);
              return (!targetPage || field.pageNumber === targetPage) && key.length > 2 && fieldKey.length > 2 &&
                (fieldKey === key || fieldKey.includes(key) || key.includes(fieldKey));
            });
            const code = item.id + "_rule_" + (rule.id || index);
            const location = targetPage ? "page " + targetPage : "the form";
            if (matched.length) {
              const empty = matched.every(field => !hasValue(field.value));
              if (empty && !rule.condition) errors.push(result(code,fileName + " — " + location + ": " + rule.label + " is blank","The library marks this item as required."));
              else if (empty) warnings.push(result(code,fileName + " — " + location + ": check " + rule.label,"This item is conditional (" + rule.condition + "). Confirm whether it applies and complete it if needed."));
              else passed.push(result(code,fileName + " — " + rule.label + " completed","The matching fillable PDF field contains a value."));
            } else {
              warnings.push(result(code,fileName + " — " + location + ": visually check " + rule.label,"The reference library expects this item" + (rule.condition ? " when " + rule.condition : "") + ". The uploaded PDF does not expose a matching fillable field, so confirm it on the original form."));
            }
          });
        } else if (libraryForms.length) {
          warnings.push(result(item.id + "_reference",fileName + ": reference form not selected","Select the matching official form from the Document Library to apply its completion checklist."));
        }
      });

      const status = errors.length ? "MISSING" : warnings.length ? "MANUAL_REVIEW" : "COMPLETE";
      const report = { errors, warnings, passed, status, checkedDocuments: files.length, totalPages: Object.values(next).reduce((sum,pages) => sum + pages.length,0), canProceed: status === "COMPLETE" };
      setReports({ pre: report, post: null });
      setShowPostReview(false);
      setMessage(errors.length ? "Some required items are missing. Correct them and run the check again." : warnings.length ? "The automated check is finished. Please complete the manual reviews listed below." : "The automated checks passed.");
    } catch (e) {
      setError(e?.message || "Paperwork validation failed.");
    } finally {
      setBusy(false);
    }
  }

  function runPostCheck() {
    if (!Object.keys(analyses).length) { setError("Run the form completion check first."); return; }
    const errors = [];
    const warnings = [];
    const passed = [];
    files.forEach(item => {
      const pages = analyses[item.id] || [];
      const reference = libraryForms.find(form => form.id === item.referenceId);
      const rules = postSignatureRules(reference?.validation_rules);
      if (rules.length) {
        rules.forEach((rule,index) => {
          const key = "rule:" + item.id + ":" + (rule.id || index);
          const label = rule.kind === "INITIAL" ? "initials" : rule.kind === "DATE" ? "signing date" : "signature";
          if (signatureChecks[key] === true) passed.push(result(key,item.file.name + " — page " + rule.page + ": " + rule.label + " confirmed","You confirmed the required " + label + " is present."));
          else errors.push(result(key,item.file.name + " — page " + rule.page + ": " + rule.label + " not confirmed","Inspect this page and confirm the required " + label + " is present and completed."));
        });
      } else {
        pages.forEach(page => {
          const key = item.id + ":" + page.pageNumber;
          if (signatureChecks[key] === true) passed.push(result(key,item.file.name + " — page " + page.pageNumber + ": signature review confirmed","You confirmed that required signatures, initials and dates are present on this page."));
          else errors.push(result(key,item.file.name + " — page " + page.pageNumber + ": signature review not confirmed","Inspect this page and confirm all required signatures, initials and dates are present."));
        });
        if (!reference) warnings.push(result(item.id + "_no_reference_post",item.file.name + ": no reference form selected","This post-signature review uses a page-by-page checklist because no library signature rules were selected."));
      }
    });
    const status = errors.length ? "MISSING" : warnings.length ? "MANUAL_REVIEW" : "COMPLETE";
    const report = { errors, warnings, passed, status, canProceed: status === "COMPLETE" };
    setReports(current => ({ ...current, post: report }));
    setMessage(errors.length ? "Post-signature review is incomplete. Check the pages or signature fields listed below." : "You confirmed the required signature review for the uploaded forms.");
  }

  function setFileValue(id,patch) {
    setFiles(current => current.map(item => item.id === id ? { ...item, ...patch } : item));
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
  }

  const resultSection = (heading,report) => report && (
    <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 16, margin: "14px 0" }}>
      <h3 style={{ marginTop: 0 }}>{heading}</h3>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <strong style={{ color: report.status === "COMPLETE" ? "#167344" : report.status === "MISSING" ? "#b42318" : "#946200" }}>
          {report.status === "COMPLETE" ? "Complete" : report.status === "MISSING" ? "Missing information" : "Manual review required"}
        </strong>
        {report.checkedDocuments !== undefined && <span className="muted">· {report.checkedDocuments} document(s), {report.totalPages} page(s)</span>}
      </div>
      {[[ "Missing information",report.errors,"#b42318" ],[ "Please review",report.warnings,"#946200" ],[ "Completed checks",report.passed,"#167344" ]].map(([label,items,color]) => items.length > 0 && (
        <div key={label} style={{ marginTop: 12 }}><strong style={{ color }}>{label}</strong>{items.map(item => <div key={item.code} style={{ marginTop: 8, padding: "8px 10px", background: "#f8f9fb", borderRadius: 6, fontSize: 13 }}><b>{item.title}</b><div className="muted">{item.detail}</div></div>)}</div>
      ))}
    </section>
  );

  return <div className="panel" style={{ maxWidth: 980, margin: "0 auto" }}>
    <div className="paneltitle">
      <div><h2><FileCheck2 size={22} style={{ verticalAlign: "middle", marginRight: 8 }}/>Paperwork Validation</h2>
        <p className="muted">Check paperwork before signing. Review signatures after the documents are signed.</p></div>
      <button className="secondary" type="button" onClick={resetValidation}><RefreshCw size={15}/> Start over</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 20 }}>
      <strong>Private temporary review</strong>
      <div className="muted">Your uploaded paperwork and results stay in this browser session. They are not saved or attached to a trade. Only official blank forms and their rules are stored in Document Library.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}

    <section style={{ border: "1px solid #e4e7ec", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
        <span style={{ background: "#0f2141", color: "#fff", borderRadius: 20, width: 28, height: 28, display: "inline-flex", alignItems: "center", justifyContent: "center", fontWeight: 700 }}>1</span>
        <h3 style={{ margin: 0 }}>Upload documents</h3>
      </div>
      <p className="muted">Upload all the forms in the package together. Match each document to its official reference form when one is available.</p>
      {libraryError && <p className="error">The reference library could not be loaded: {libraryError}</p>}
      {!libraryForms.length && !libraryError && <div className="muted" style={{ padding: 10, background: "#f8f9fb", borderRadius: 6, marginBottom: 12 }}>No official reference forms are published yet. An administrator must add them in Document Library before automatic form-specific checks are available.</div>}
      <label className="secondary" style={{ display: "inline-flex", alignItems: "center", gap: 8, cursor: "pointer", marginBottom: 12 }}>
        <Upload size={16}/> Choose files
        <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff" style={{ display: "none" }} onChange={event => { addFiles(event.target.files); event.target.value = ""; }}/>
      </label>
      {files.length > 0 && <div style={{ display: "grid", gap: 8, marginBottom: 14 }}>
        {files.map(item => <div key={item.id} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(190px,280px) auto", alignItems: "center", gap: 10, border: "1px solid #e4e7ec", borderRadius: 8, padding: 10 }}>
          <span title={item.file.name} style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}><FileText size={18}/><span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.file.name}</span></span>
          <select aria-label={"Official reference for " + item.file.name} value={item.referenceId} onChange={e => setFileValue(item.id,{referenceId:e.target.value})} style={{ minWidth: 0 }}>
            <option value="">Choose matching reference form…</option>
            {libraryForms.map(form => <option key={form.id} value={form.id}>{form.document_name} · v{form.version}</option>)}
          </select>
          <button type="button" className="textbutton" aria-label={"Remove " + item.file.name} onClick={() => { setFiles(current => current.filter(file => file.id !== item.id)); setAnalyses({}); setReports({ pre: null, post: null }); setShowPostReview(false); }}><Trash2 size={16}/></button>
        </div>)}
        <button className="primary" type="button" disabled={busy || !files.length} onClick={runPreCheck}>{busy ? "Checking documents…" : "Check form completion"}</button>
      </div>}
    </section>

    {resultSection("2. Form completion results",reports.pre)}
    {reports.pre && <section style={{ border: "1px solid #e4e7ec", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
        <span style={{ background: "#0f2141", color: "#fff", borderRadius: 20, width: 28, height: 28, display: "inline-flex", alignItems: "center", justifyContent: "center", fontWeight: 700 }}>3</span>
        <h3 style={{ margin: 0 }}>Review signatures after signing</h3>
      </div>
      <p className="muted">When the documents have been signed, open this review and check the required signatures, initials and dates. Handwritten signatures must be visually checked by a person.</p>
      {!showPostReview ? <button className="secondary" type="button" onClick={() => { setShowPostReview(true); setReports(current => ({ ...current, post: null })); }}>Start signature review</button> : <>
        {files.map(item => {
          const pages = analyses[item.id] || [];
          const reference = libraryForms.find(form => form.id === item.referenceId);
          const rules = postSignatureRules(reference?.validation_rules);
          return <div key={item.id} style={{ marginTop: 14, paddingTop: 12, borderTop: "1px solid #e4e7ec" }}>
            <strong title={item.file.name}>{item.file.name}</strong>
            {rules.length ? rules.map((rule,index) => {
              const key = "rule:" + item.id + ":" + (rule.id || index);
              const kind = rule.kind === "INITIAL" ? "initials" : rule.kind === "DATE" ? "signing date" : "signature";
              return <label key={key} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 10 }}>
                <input type="checkbox" checked={signatureChecks[key] === true} onChange={e => setSignatureChecks(current => ({ ...current, [key]: e.target.checked })}/>
                <span>Page {rule.page}: Confirm {kind.toLowerCase()} for {rule.label} is present.</span>
              </label>;
            }) : pages.map(page => {
              const key = item.id + ":" + page.pageNumber;
              return <label key={key} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 10 }}>
                <input type="checkbox" checked={signatureChecks[key] === true} onChange={e => setSignatureChecks(current => ({ ...current, [key]: e.target.checked })}/>
                <span>Page {page.pageNumber}: I checked all required signatures, initials and dates.</span>
              </label>;
            })}
          </div>;
        })}
        <div style={{ display: "flex", gap: 8, marginTop: 16, flexWrap: "wrap" }}>
          <button className="primary" type="button" disabled={busy} onClick={runPostCheck}>Complete signature review</button>
          <button className="secondary" type="button" onClick={() => { setShowPostReview(false); setReports(current => ({ ...current, post: null })); }}>Close review</button>
        </div>
        {resultSection("Signature review results",reports.post)}
      </>}
    </section>}
    <div className="muted" style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 14, fontSize: 12 }}><AlertCircle size={15}/> A result marked “Manual review required” is not a pass. Check the original document yourself. The system cannot confirm the authenticity of a signature.</div>
  </div>;
}
