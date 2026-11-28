import React from "react";
import { createRoot } from "react-dom/client";
import FieldApp from "./FieldApp.jsx";
import "./field.css";

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(error => console.warn("DV app service worker registration failed:", error)));
}

createRoot(document.getElementById("root")).render(
  <React.StrictMode><FieldApp /></React.StrictMode>
);