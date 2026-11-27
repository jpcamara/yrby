// Registers the two elements of this package.
import { CollaborativeField } from "./collaborative_field.js";
import { CollaborativeFields } from "./collaborative_fields.js";

export { CollaborativeField, CollaborativeFields };

for (const [name, element] of [
  ["collaborative-field", CollaborativeField],
  ["collaborative-fields", CollaborativeFields],
] as const) {
  if (!customElements.get(name)) customElements.define(name, element);
}
