// yrby-forms: collaborative form fields over yrby. Importing this module
// registers the two custom elements the Rails form helpers render.
import { CollaborativeForm } from "./collaborative_form.js";
import { CollaborativeField } from "./collaborative_field.js";

export { CollaborativeForm } from "./collaborative_form.js";
export { CollaborativeField } from "./collaborative_field.js";
export { setConsumer } from "./consumer.js";

if (!customElements.get("collaborative-form")) {
  customElements.define("collaborative-form", CollaborativeForm);
}
if (!customElements.get("collaborative-field")) {
  customElements.define("collaborative-field", CollaborativeField);
}
