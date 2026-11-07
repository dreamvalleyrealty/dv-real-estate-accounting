import React from "react";
import { createRoot } from "react-dom/client";
import FieldApp from "./FieldApp.jsx";
import "./field.css";

createRoot(document.getElementById("root")).render(
  <React.StrictMode><FieldApp /></React.StrictMode>
);