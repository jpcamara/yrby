import { Doc } from "yjs";
import { ActionCableProvider, type CableConsumer } from "yrby-client";
export declare class CollaborativeForm extends HTMLElement {
    #private;
    doc: Doc;
    provider: ActionCableProvider;
    /** Assign before insertion to use a specific consumer (e.g. @anycable/web). */
    consumer?: CableConsumer;
    connectedCallback(): void;
    disconnectedCallback(): void;
    get awareness(): import("y-protocols/awareness.js").Awareness;
}
