import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import { Awareness, applyAwarenessUpdate } from "y-protocols/awareness";
import { MessageType, fromBase64, toBase64 } from "../dist/index.js";

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
// The presence a peer sees for `clientID` after applying the awareness frames
// in `messages`, whether they were sent or whispered.
export function presenceSent(messages, clientID) {
  const peer = new Awareness(new Y.Doc());
  for (const message of messages) {
    const frame = message.awareness ?? message.update;
    if (!frame) continue;
    const decoder = decoding.createDecoder(fromBase64(frame));
    if (decoding.readVarUint(decoder) !== MessageType.Awareness) continue;
    applyAwarenessUpdate(peer, decoding.readVarUint8Array(decoder), "peer");
  }
  const state = peer.getStates().get(clientID) ?? null;
  peer.destroy();
  return state;
}
export function ack(sub) {
  const frame = sub.sent.filter(m => m.id !== undefined).at(-1);
  if (!frame) throw new Error("No tracked update was sent");
  sub.handlers.received({ ack: frame.id });
}
