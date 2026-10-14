import { useEffect, useRef, useState } from "react";

function cleanMoney(value) {
  let text = String(value ?? "").replace(/[,$%\\s]/g, "").replace(/[^0-9.\\-]/g, "");
  const negative = text.startsWith("-");
  text = text.replace(/-/g, "");
  const point = text.indexOf(".");
  if (point >= 0) text = text.slice(0, point) + "." + text.slice(point + 1).replace(/\\./g, "");
  if (text.startsWith(".")) text = "0" + text;
  if (negative && text) text = "-" + text;
  return text;
}

function displayMoney(value) {
  const raw = cleanMoney(value);
  if (!raw || raw === "-" || raw === "." || raw === "-.") return "";
  const number = Number(raw);
  if (!Number.isFinite(number)) return "";
  return new Intl.NumberFormat("en-CA", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
    useGrouping: true
  }).format(number);
}

/**
 * A currency input that keeps numeric strings in form state while displaying
 * a dollar prefix and two decimal places. It intentionally calls onChange
 * with an event-like target.value so existing form handlers remain compatible.
 */
export default function MoneyInput({
  value,
  onChange,
  onBlur,
  onFocus,
  min,
  max,
  step = "0.01",
  required = false,
  disabled = false,
  readOnly = false,
  style,
  className = "",
  prefix = "$",
  suffix = "",
  ...inputProps
}) {
  const inputRef = useRef(null);
  const [focused, setFocused] = useState(false);
  const rawValue = cleanMoney(value);
  const [draft, setDraft] = useState(rawValue);

  useEffect(() => {
    if (!focused) setDraft(rawValue);
  }, [rawValue, focused]);

  const emit = nextValue => onChange?.({ target: { value: nextValue }, currentTarget: { value: nextValue } });

  const validate = raw => {
    const input = inputRef.current;
    if (!input) return;
    if (!raw) {
      input.setCustomValidity("");
      return;
    }
    const amount = Number(raw);
    if (!Number.isFinite(amount)) {
      input.setCustomValidity("Enter a valid amount.");
    } else if (min !== undefined && min !== null && amount < Number(min)) {
      input.setCustomValidity("Enter an amount of at least " + displayMoney(min) + ".");
    } else if (max !== undefined && max !== null && amount > Number(max)) {
      input.setCustomValidity("Enter an amount no greater than " + displayMoney(max) + ".");
    } else {
      input.setCustomValidity("");
    }
  };

  const wrapperStyle = {
    display: "flex",
    alignItems: "center",
    gap: 4,
    boxSizing: "border-box",
    width: style?.width || "100%",
    minWidth: 0,
    minHeight: style?.minHeight || 38,
    border: style?.border || "1px solid #d0d5dd",
    borderRadius: style?.borderRadius || 8,
    padding: style?.padding || "7px 10px",
    background: disabled ? "#f2f4f7" : (style?.background || "#fff"),
    color: style?.color || "#101828",
    opacity: disabled ? 0.7 : 1,
    ...style
  };

  return (
    <div className={"money-input-wrap " + className} style={wrapperStyle} data-money-input="true">
      <span className="money-input-prefix" aria-hidden="true" style={{ flex: "0 0 auto", fontWeight: 650 }}>
        {prefix}
      </span>
      <input
        {...inputProps}
        ref={inputRef}
        className="money-input-control"
        type="text"
        inputMode="decimal"
        value={focused ? draft : displayMoney(value)}
        required={required}
        disabled={disabled}
        readOnly={readOnly}
        data-step={step}
        data-min={min}
        data-max={max}
        onFocus={event => {
          setFocused(true);
          setDraft(cleanMoney(value));
          inputRef.current?.setCustomValidity("");
          onFocus?.(event);
        }}
        onChange={event => {
          const next = cleanMoney(event.target.value);
          setDraft(next);
          inputRef.current?.setCustomValidity("");
          emit(next);
        }}
        onBlur={event => {
          const raw = cleanMoney(draft);
          const numeric = raw && raw !== "-" && raw !== "." && raw !== "-." ? Number(raw) : null;
          const finalValue = numeric !== null && Number.isFinite(numeric) ? numeric.toFixed(2) : "";
          setDraft(finalValue);
          setFocused(false);
          validate(finalValue);
          emit(finalValue);
          onBlur?.(event);
        }}
        style={{
          display: "block",
          flex: "1 1 auto",
          minWidth: 0,
          width: "100%",
          border: 0,
          borderRadius: 0,
          padding: 0,
          margin: 0,
          outline: "none",
          boxShadow: "none",
          background: "transparent",
          color: "inherit",
          font: "inherit",
          appearance: "textfield"
        }}
      />
    </div>
  );
}
