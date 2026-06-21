// Zero-dependency reliable-delivery core. Safe to import on its own.
export { ReliableSync } from "./reliable_sync.js";
export type { ReliableSyncOptions, TimerHandle } from "./reliable_sync.js";

// Batteries-included protocol session (sync steps + encode/decode + awareness).
// Requires `yjs` and `y-protocols` as peers.
export { YProtocolSession, MessageType } from "./y_protocol_session.js";
export type { YProtocolSessionOptions, SendOptions } from "./y_protocol_session.js";

// Ready-made ActionCable / AnyCable provider built on YProtocolSession (with awareness
// whisper support). Bring your own provider instead by composing YProtocolSession.
export { ActionCableProvider } from "./actioncable_provider.js";
export type {
  ActionCableProviderOptions,
  ProviderStatus,
  StatusEvent,
  CableConsumer,
  CableSubscription,
} from "./actioncable_provider.js";

// Optional base64 helpers for transports that carry frames as strings.
export { toBase64, fromBase64 } from "./base64.js";
