// A ready-made Yjs provider for the yrb-lite y-websocket protocol over
// ActionCable / AnyCable. It owns the cable subscription and translates between
// the cable's JSON envelope (`{ update, id }` / `{ ack }`, base64) and raw
// protocol frames; everything else (sync steps, encode/decode, awareness,
// reliable delivery) lives in YProtocolSession. So this is just the transport glue.
//
// Awareness/presence frames are sent via AnyCable's `whisper` when the
// subscription supports it (client-to-client, no server round-trip); on plain
// ActionCable (no `whisper`) they fall back to a normal `send` and the server
// relays them. Document updates always go through `send` (they must be
// recorded/acked).
//
// The constructor does NOT auto-connect: wire your editor binding first, then
// call `connect()`. Same `(doc, consumer, channelName, channelParams, opts)`
// shape as a typical y-rb/actioncable provider.
import { YProtocolSession, MessageType, type YProtocolSessionOptions, type SendOptions } from "./y_protocol_session.js";
import { toBase64, fromBase64 } from "./base64.js";
import { Awareness } from "y-protocols/awareness";
import type { Doc } from "yjs";

/** The minimal slice of an ActionCable/AnyCable subscription this provider uses. */
export interface CableSubscription {
  send(data: unknown): unknown;
  /** AnyCable client-to-client broadcast; absent on plain ActionCable. */
  whisper?(data: unknown): unknown;
  unsubscribe?(): void;
}

/** The minimal slice of an ActionCable/AnyCable consumer this provider uses. */
export interface CableConsumer {
  subscriptions: {
    create(params: object, mixin: object): CableSubscription;
    remove(subscription: CableSubscription): void;
  };
}

export interface ActionCableProviderOptions
  extends Pick<YProtocolSessionOptions, "reliable" | "resendInterval" | "maxUnconfirmedResends" | "onFallback"> {
  /** Awareness/presence instance. Defaults to a fresh `new Awareness(doc)`. */
  awareness?: Awareness | null;
}

interface CableMessage {
  m?: string;
  update?: string;
  ack?: number;
}

export class ActionCableProvider {
  readonly doc: Doc;
  readonly consumer: CableConsumer;
  readonly channelName: string;
  readonly channelParams: object;
  readonly awareness: Awareness;
  readonly session: YProtocolSession;
  private subscription: CableSubscription | null = null;

  constructor(
    doc: Doc,
    consumer: CableConsumer,
    channelName: string,
    channelParams: object = {},
    opts: ActionCableProviderOptions = {}
  ) {
    this.doc = doc;
    this.consumer = consumer;
    this.channelName = channelName;
    this.channelParams = channelParams;
    this.awareness = opts.awareness ?? new Awareness(doc);

    this.session = new YProtocolSession(doc, {
      awareness: this.awareness,
      reliable: opts.reliable,
      resendInterval: opts.resendInterval,
      maxUnconfirmedResends: opts.maxUnconfirmedResends,
      onFallback: opts.onFallback,
      send: (frame, id, sendOpts) => this._send(frame, id, sendOpts),
    });
  }

  /** True once the document has caught up with the server (received a SyncStep2). */
  get synced(): boolean {
    return this.session.synced;
  }

  /** True while there are unacknowledged local document updates in flight. */
  get hasPending(): boolean {
    return this.session.hasPending;
  }

  connect(): void {
    if (this.subscription) return;
    const provider = this;
    this.subscription = this.consumer.subscriptions.create(
      { channel: this.channelName, ...this.channelParams },
      {
        received(message: CableMessage) {
          // Reliable-delivery ack: confirm + prune the local queue.
          if (message && message.ack !== undefined) {
            provider.session.ack(message.ack);
            return;
          }
          const payload = message && (message.m ?? message.update);
          if (typeof payload !== "string") return;
          const reply = provider.session.receive(fromBase64(payload));
          if (reply) provider._send(reply, undefined); // e.g. SyncStep2 answering a SyncStep1
        },
        connected() {
          provider.session.onConnect(); // handshake + replay the unacked tail
        },
        disconnected() {
          provider.session.onDisconnect(); // pause retransmits, clear remote presence
        },
      }
    );
  }

  disconnect(): void {
    if (!this.subscription) return;
    this.session.onDisconnect();
    this.consumer.subscriptions.remove(this.subscription);
    this.subscription = null;
  }

  destroy(): void {
    this.disconnect();
    this.session.destroy();
  }

  // Send one raw protocol frame over the cable. Awareness frames are whispered
  // when the subscription supports it (AnyCable), else sent normally; document
  // frames always go through `send`. `id` (reliable doc updates) is tagged onto
  // the envelope so the server can ack. A no-op while disconnected: reliable
  // frames stay queued in the session and flush on the next connect().
  private _send(frame: Uint8Array, id: number | undefined, opts?: SendOptions): void {
    const sub = this.subscription;
    if (!sub) return;
    const update = toBase64(frame);
    const payload = id === undefined ? { update } : { update, id };
    const isAwareness = opts?.awareness ?? frame[0] === MessageType.Awareness;
    // Awareness rides AnyCable's whisper automatically when the subscription
    // supports it (client-to-client, no server round-trip); otherwise a normal
    // send the server relays. Document updates always send (recorded/acked).
    if (isAwareness && typeof sub.whisper === "function") sub.whisper(payload);
    else sub.send(payload);
  }
}
