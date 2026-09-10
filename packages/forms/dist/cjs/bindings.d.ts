import type * as Y from "yjs";
/** The map share holding the LWW entries; text shares live at `fields/<name>`. */
export declare const FIELDS_MAP = "fields";
export type BoundControl = HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement;
/**
 * The one changed region between two strings, as a splice: common prefix and
 * suffix stay, the middle becomes one delete + one insert. Null when equal.
 */
export declare function diffSplice(oldValue: string, newValue: string): {
    index: number;
    deleteCount: number;
    insert: string;
} | null;
/** Bind a control to the shared map entry under `name`. Returns the unbind. */
export declare function bindLww(doc: Y.Doc, name: string, control: BoundControl): () => void;
/** Bind a text control to the `fields/<name>` Y.Text. Returns the unbind. */
export declare function bindText(doc: Y.Doc, name: string, control: HTMLInputElement | HTMLTextAreaElement): () => void;
