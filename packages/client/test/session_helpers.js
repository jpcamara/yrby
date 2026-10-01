import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { MessageType, toBase64 } from "../dist/index.js";

export const tick = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
export function fakeConsumer() {
  const subscriptions = [];
  const consumer = { subscriptions: { create(params, handlers) {
    const sub = { params, handlers, sent: [], removed: false,
      send(message) { this.sent.push(message); }, unsubscribe() { this.removed = true; } };
    subscriptions.push(sub);
    return sub;
  } }, created: subscriptions };
  return consumer;
}
export function sync(sub, text = "") {
  sub.handlers.connected();
  const doc = new Y.Doc();
  if (text) doc.getText("content").insert(0, text);
  const encoder = encoding.createEncoder();
  encoding.writeVarUint(encoder, MessageType.Sync);
  encoding.writeVarUint(encoder, 1);
  encoding.writeVarUint8Array(encoder, Y.encodeStateAsUpdate(doc));
  sub.handlers.received({ update: toBase64(encoding.toUint8Array(encoder)) });
  doc.destroy();
}
export function ack(sub) {
  const frame = sub.sent.filter(m => m.id !== undefined).at(-1);
  if (!frame) throw new Error("No tracked update was sent");
  sub.handlers.received({ ack: frame.id });
}
