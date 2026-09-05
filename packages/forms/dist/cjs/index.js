"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setConsumer = exports.CollaborativeField = exports.CollaborativeForm = void 0;
// yrby-forms: collaborative form fields over yrby. Importing this module
// registers the two custom elements the Rails form helpers render.
const collaborative_form_js_1 = require("./collaborative_form.js");
const collaborative_field_js_1 = require("./collaborative_field.js");
var collaborative_form_js_2 = require("./collaborative_form.js");
Object.defineProperty(exports, "CollaborativeForm", { enumerable: true, get: function () { return collaborative_form_js_2.CollaborativeForm; } });
var collaborative_field_js_2 = require("./collaborative_field.js");
Object.defineProperty(exports, "CollaborativeField", { enumerable: true, get: function () { return collaborative_field_js_2.CollaborativeField; } });
var consumer_js_1 = require("./consumer.js");
Object.defineProperty(exports, "setConsumer", { enumerable: true, get: function () { return consumer_js_1.setConsumer; } });
if (!customElements.get("collaborative-form")) {
    customElements.define("collaborative-form", collaborative_form_js_1.CollaborativeForm);
}
if (!customElements.get("collaborative-field")) {
    customElements.define("collaborative-field", collaborative_field_js_1.CollaborativeField);
}
