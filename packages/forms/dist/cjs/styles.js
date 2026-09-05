"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ensureStyles = ensureStyles;
// The presence affordances' stylesheet, injected once per document. Apps
// restyle by overriding these selectors (nothing here is !important) or by
// pre-inserting their own element with the same id, which suppresses the
// injection entirely.
const STYLE_ID = "yrby-forms-styles";
function ensureStyles(doc) {
    if (doc.getElementById(STYLE_ID))
        return;
    const style = doc.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
collaborative-field { display: block; position: relative; }
collaborative-field[data-remote] :is(input, textarea, select) {
  outline: 2px solid var(--collaborative-field-color, #958DF1);
  outline-offset: 1px;
}
.collaborative-field-chip {
  position: absolute;
  top: 0;
  right: 0;
  transform: translateY(-100%);
  color: #fff;
  padding: 1px 6px;
  border-radius: 999px;
  font: 11px system-ui, sans-serif;
  pointer-events: none;
}
`;
    doc.head.appendChild(style);
}
