// Zero-dependency reliable-delivery core. Safe to import on its own.
export { ReliableSync } from "./reliable_sync.js";
export type { ReliableSyncOptions, TimerHandle } from "./reliable_sync.js";

// Protocol session (sync steps + encode/decode + awareness).
// Requires `yjs` and `y-protocols` as peers.
export { YProtocolSession, MessageType } from "./y_protocol_session.js";
export type { YProtocolSessionOptions } from "./y_protocol_session.js";

// ActionCable / AnyCable provider built on YProtocolSession.
// Bring your own provider instead by composing YProtocolSession.
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

// Document ownership for editor attachments and headless application workflows.
export { DocumentSessionStore } from "./document_session.js";
export type { DocumentSession, DocumentAttachment, DocumentDescriptor, DocumentSessionState, DocumentRecovery } from "./document_session.js";
