// <yrby-document> — the auto-connecting element for the gem-shipped
// Y::DocumentChannel, the way <turbo-cable-stream-source> auto-connects for
// Turbo::StreamsChannel. collaborative_document_tag renders it with the signed
// grant; importing "yrby-client/element" registers it; connection needs no
// per-feature JavaScript.
//
//   <yrby-document grant="..." name="body"></yrby-document>
//
// The one thing an element cannot do alone is finish the job: the payload is
// a Y.Doc that your editor binding must receive. Take it from the `doc`
// property, after the first sync (binding earlier makes each client seed its
// own competing top-level node):
//
//   document.querySelector("yrby-document")
//     .addEventListener("yrby:synced", ({ target }) => bindEditor(target.doc))
//
// or `await el.whenSynced` once the element is connected.
//
// All elements on a page share one cable consumer. By default it is created
// from "@rails/actioncable" (an optional peer dependency, imported only when
// used); an app on AnyCable assigns its own once, before the elements connect:
//
//   YrbyDocumentElement.consumer = createCable(...)
import * as Y from "yjs";
import { ActionCableProvider } from "./actioncable_provider.js";
import type { CableConsumer } from "./actioncable_provider.js";

// Node (SSR, tests) has no HTMLElement; parsing must not crash there, so the
// class exists everywhere and only registration is browser-gated below.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;

let sharedConsumer: CableConsumer | undefined;

async function defaultConsumer(): Promise<CableConsumer> {
  if (!sharedConsumer) {
    const actioncable = await import("@rails/actioncable");
    sharedConsumer = actioncable.createConsumer() as CableConsumer;
  }
  return sharedConsumer;
}

export class YrbyDocumentElement extends Base {
  /** Assign once for AnyCable (or any custom consumer); default is @rails/actioncable's. */
  static consumer: CableConsumer | undefined;

  doc: Y.Doc = new Y.Doc();
  provider: ActionCableProvider | undefined;

  async connectedCallback(): Promise<void> {
    if (this.provider) {
      // Re-inserted (Turbo restore, DOM move): same doc, same provider, resubscribe.
      this.provider.connect();
      return;
    }

    const consumer = YrbyDocumentElement.consumer ?? (await defaultConsumer());
    this.provider = new ActionCableProvider(this.doc, consumer, this.channelName, {
      grant: this.getAttribute("grant"),
      name: this.getAttribute("name"),
    });
    this.provider.connect();
    void this.provider.whenSynced.then(() => {
      this.dispatchEvent(
        new CustomEvent("yrby:synced", {
          bubbles: true,
          detail: { doc: this.doc, provider: this.provider },
        }),
      );
    });
  }

  disconnectedCallback(): void {
    this.provider?.disconnect();
  }

  /** Resolves after the first catch-up with the server. Available once connected. */
  get whenSynced(): Promise<void> | undefined {
    return this.provider?.whenSynced;
  }

  private get channelName(): string {
    return this.getAttribute("channel") || "Y::DocumentChannel";
  }
}

if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
