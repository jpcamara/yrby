// <collaborative-form>: the container for one record's collaborative field
// set. Builds an Action Cable consumer, a Y.Doc, and yrby-client's
// ActionCableProvider from its attributes, and carries the presence identity
// its <collaborative-field> children announce on focus. The Rails form helper
// (form.collaborative_fields) renders the attributes; nothing here is
// hand-written in an app.
//
//   <collaborative-form channel="FormFieldsChannel" sgid="..."
//                       doc-key="ticket-1-fields" name="Ada" color="#22d3ee">
//     <collaborative-field name="status" tier="lww">…</collaborative-field>
//   </collaborative-form>
//
// The provider's connection status is reflected into the element's `status`
// attribute (connecting / connected / synced / disconnected) for styling.
import { Doc } from "yjs";
import { ActionCableProvider } from "yrby-client";
import { resolveConsumer } from "./consumer.js";
export class CollaborativeForm extends HTMLElement {
    doc;
    provider;
    /** Assign before insertion to use a specific consumer (e.g. @anycable/web). */
    consumer;
    #teardown = null;
    connectedCallback() {
        const channelName = this.getAttribute("channel") || "FormFieldsChannel";
        const docKey = this.getAttribute("doc-key");
        this.doc = new Doc(docKey ? { guid: docKey } : undefined);
        this.provider = new ActionCableProvider(this.doc, this.consumer ?? resolveConsumer(), channelName, {
            sgid: this.getAttribute("sgid") || "",
        });
        // The presence identity every field announces from. Names are cosmetic
        // (client-authored); access is the server's sgid + authorized? layer.
        this.provider.awareness.setLocalState({
            name: this.getAttribute("name") || "Anonymous",
            color: this.getAttribute("color") || "#958DF1",
            field: null,
        });
        const offStatus = this.provider.onStatusChange(({ status }) => this.setAttribute("status", status));
        this.setAttribute("status", this.provider.status);
        this.provider.connect();
        this.#teardown = () => {
            offStatus();
            this.provider.destroy();
        };
    }
    disconnectedCallback() {
        this.#teardown?.();
        this.#teardown = null;
    }
    get awareness() {
        return this.provider.awareness;
    }
}
//# sourceMappingURL=collaborative_form.js.map