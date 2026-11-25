// yrby-forms: collaborative form fields over yrby. Importing this module
// registers <collaborative-field>, and yrby-client's <yrby-document>, which
// the Rails form helpers render around the fields.
import "yrby-client/element";
import { CollaborativeField } from "./collaborative_field.js";

export { CollaborativeField } from "./collaborative_field.js";

if (!customElements.get("collaborative-field")) {
  customElements.define("collaborative-field", CollaborativeField);
}
