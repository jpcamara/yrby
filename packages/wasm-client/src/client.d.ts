import type * as Yrs from "ywasm"
import type { ReliableSync } from "yrby-client/reliable"

export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue }
export type Presence = { [key: string]: JSONValue }
export type ProviderStatus = "disconnected" | "connecting" | "connected" | "synced"
export type Unsubscribe = () => void
export const LOCAL_ORIGIN: "yrby-wasm-local"

/** Minimal ActionCable/AnyCable transport shape; an existing consumer stays shared. */
export interface CableConsumer {
  subscriptions: { create(channel: string | object, mixin?: object): CableSubscription }
  connect?(): void
  disconnect?(): void
}
export interface CableSubscription {
  send(message: unknown): unknown
  whisper?(message: unknown): unknown
  unsubscribe?(): void
}

export interface ClientOptions {
  /** The host must initialize the ywasm module before creating a client. */
  Y: typeof Yrs
  consumer: CableConsumer
  channel?: string
  params?: Record<string, unknown>
  localState?: Presence | null
  resendInterval?: number
  onError?: (error: unknown, context: string) => void
  /** Set only when this consumer belongs exclusively to this client. Default false. */
  manageConsumer?: boolean
}

/** Parsed shape of getStatus() and the JSON passed to onStatus listeners. */
export interface ClientStatus {
  status: ProviderStatus
  connected: boolean
  synced: boolean
  offline: boolean
  pending: number
  clientID: number
  error: string
  peers: Array<Presence & { clientID: number }>
  canUndo: boolean
  canRedo: boolean
}

export interface SharedType<Native> {
  /** Escape hatch. Respect Yrs wrapper ownership and active transaction rules. */
  readonly native: Native
  readonly name: string
  readonly kind: "Map" | "Text" | "Array"
  readonly length: number
  readJSON(): string
}
export interface SharedMap extends SharedType<Yrs.YMap> {
  readonly kind: "Map"
  /** Returns JSON null for an absent entry. Use has() to distinguish stored null. */
  getJSON(key: string): string
  has(key: string): boolean
  setJSON(key: string, json: string): void
  delete(key: string): void
  keysJSON(): string
}
export interface SharedText extends SharedType<Yrs.YText> {
  readonly kind: "Text"
  /** Length and offsets count UTF-16 code units, matching Yjs and the DOM. */
  readonly length: number
  toString(): string
  insert(index: number, text: string): void
  delete(index: number, length: number): void
}
export interface SharedArray extends SharedType<Yrs.YArray> {
  readonly kind: "Array"
  getJSON(index: number): string
  /** json must encode an array of values to insert. */
  insertJSON(index: number, json: string): void
  delete(index: number, length?: number): void
}

export interface UndoState { canUndo: boolean; canRedo: boolean }
export interface UndoManager {
  readonly native: Yrs.YUndoManager
  readonly canUndo: boolean
  readonly canRedo: boolean
  undo(): void
  redo(): void
  stopCapturing(): void
  clear(): void
  /** Deferred callback receives JSON encoding UndoState. */
  onChange(listener: (json: string) => void): Unsubscribe
  destroy(): void
}
export type UndoScope = string | SharedMap | SharedText | SharedArray | Yrs.YMap | Yrs.YText | Yrs.YArray

export interface WasmClient {
  readonly doc: Yrs.YDoc
  readonly awareness: Yrs.Awareness
  readonly delivery: ReliableSync
  readonly consumer: CableConsumer
  readonly clientID: number
  readonly stats: { localUpdates: number; remoteUpdates: number; acknowledgments: number }
  readonly status: ProviderStatus
  readonly synced: boolean
  readonly hasPending: boolean
  /** Resolves after first sync; remains resolved during later reconnects. */
  readonly whenSynced: Promise<void>
  /** Resolves when the pending delivery queue empties. Destroy does not resolve it. */
  readonly whenAcknowledged: Promise<void>
  /** Defensive copy of the unacknowledged update tail, or null. */
  readonly pendingUpdate: Uint8Array | null
  map(name: string): SharedMap
  text(name: string): SharedText
  array(name: string): SharedArray
  createUndoManager(scope: UndoScope[], origin?: string, captureTimeout?: number): UndoManager
  /** Open shared roots first. Transactions batch operations and do not roll back. */
  beginTransaction(origin?: string): void
  endTransaction(): void
  setPresenceJSON(json: string): void
  getPresenceJSON(): string
  getStatus(): string
  /** Integrates durable state without adding a local delivery obligation. */
  applyRemoteUpdate(update: Uint8Array): void
  /** Integrates and queues an unsent tail, including already integrated structs. */
  restorePendingUpdate(update: Uint8Array): void
  encodeStateAsUpdate(vector?: Uint8Array): Uint8Array
  encodeStateVector(): Uint8Array
  connect(): void
  disconnect(): void
  renew(params: Record<string, unknown>): void
  /** Deferred until the active Yrs transaction has been released. */
  onChange(listener: () => void): Unsubscribe
  /** Deferred callback receives JSON encoding ClientStatus. */
  onStatus(listener: (json: string) => void): Unsubscribe
  onStatusChange(listener: (event: { status: ProviderStatus }) => void): Unsubscribe
  destroy(): void
}

/** Experimental browser client; no network connection starts until connect(). */
export function createClient(options: ClientOptions): WasmClient
