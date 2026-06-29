// Transport-agnostic reliable-delivery core for the yrby y-websocket
// protocol: an ack-tracked queue of unacknowledged local updates,
// sync-since-last-ack (the unacked tail goes out as one merged, causally-complete
// delta so the server never sees an internal gap), cumulative acks, periodic
// retransmit, and reconnect replay.
//
// It doesn't touch the transport, the Yjs binding, or wire encoding. Inject two
// functions:
// send(update, id) transmits one update (raw merged bytes plus a cumulative
// sequence id; you frame, base64, and put it on the socket), and merge(updates)
// merges update byte-arrays into one (usually Y.mergeUpdates). Drive it from the
// provider lifecycle: enqueue(update) on each local edit, onAck(id) when an
// { ack: id } frame arrives, and onConnect()/onDisconnect() on transport changes.
//
// Awareness/presence stays out of scope; it's fire-and-forget in the provider.

/** An opaque timer handle (number in browsers, Timeout in Node). */
export type TimerHandle = unknown;

export interface ReliableSyncOptions {
  /**
   * Transmit one update. `update` is the raw merged update bytes; `id` is the
   * cumulative sequence to ack against.
   */
  send: (update: Uint8Array, id: number) => void;
  /** Merge an array of update byte-arrays into one (typically Y.mergeUpdates). */
  merge: (updates: Uint8Array[]) => Uint8Array;
  /** Milliseconds between retransmits of the unacked tail (default 1000). */
  resendInterval?: number;
  /** Injectable timer hooks (default to globals); handy for tests. */
  setInterval?: (handler: () => void, ms: number) => TimerHandle;
  clearInterval?: (handle: TimerHandle) => void;
}

const DEFAULTS = { resendInterval: 1000 };

interface Pending {
  seq: number;
  update: Uint8Array;
}

export class ReliableSync {
  /** Unacked local updates, in order. */
  pending: Pending[] = [];

  #send: ReliableSyncOptions["send"];
  #merge: ReliableSyncOptions["merge"];
  #resendInterval: number;
  #setInterval: (handler: () => void, ms: number) => TimerHandle;
  #clearInterval: (handle: TimerHandle) => void;

  #nextSeq = 1;
  #connected = false;
  #timer: TimerHandle | undefined = undefined;
  // Memoized merge of the unacked tail. The tail only changes on enqueue/ack, so
  // retransmit ticks reuse this instead of re-merging the whole queue each time.
  #tailCache: Uint8Array | undefined = undefined;

  constructor(opts: ReliableSyncOptions) {
    const { send, merge, resendInterval } = opts ?? ({} as ReliableSyncOptions);
    if (typeof send !== "function") throw new TypeError("ReliableSync requires a send(update, id) function");
    if (typeof merge !== "function") throw new TypeError("ReliableSync requires a merge(updates) function");

    this.#send = send;
    this.#merge = merge;
    const interval = resendInterval ?? DEFAULTS.resendInterval;
    if (!Number.isFinite(interval) || interval <= 0) {
      throw new TypeError("ReliableSync resendInterval must be a positive number");
    }
    this.#resendInterval = interval;
    // Injectable timer hooks make the resend loop testable; default to globals.
    this.#setInterval = opts.setInterval ?? ((fn, ms) => setInterval(fn, ms));
    this.#clearInterval = opts.clearInterval ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>));
  }

  /** True while there are unacknowledged local updates. */
  get hasPending(): boolean {
    return this.pending.length > 0;
  }

  /**
   * Record a local document update. It is queued and the unacked tail is
   * flushed; the update remains retained until the server acknowledges it.
   */
  enqueue(update: Uint8Array): void {
    this.pending.push({ seq: this.#nextSeq++, update });
    this.#tailCache = undefined; // tail changed
    if (this.#connected) this.#startTimer();
    this.flush();
  }

  /**
   * Send the whole unacked tail as one merged delta. The id is the highest seq
   * in the batch, so a single { ack } cumulatively confirms everything up to it.
   * No-op while disconnected (the tail is replayed on the next onConnect).
   */
  flush(): void {
    if (!this.#connected || this.pending.length === 0) return;
    this.#send(this.#mergedTail(), this.pending[this.pending.length - 1].seq);
  }

  /**
   * Confirm delivery up to `id`: prune every queued update with seq <= id.
   * Acks arrive over the wire, so validate before pruning. A malformed value
   * (NaN/string/negative) or an impossible future id must not silently drop the
   * queue; invalid acks are ignored.
   */
  onAck(id: number): void {
    if (!Number.isSafeInteger(id) || id < 0) return; // malformed / impossible
    if (this.pending.length > 0 && id > this.pending[this.pending.length - 1].seq) return; // future ack
    this.pending = this.pending.filter((p) => p.seq > id);
    this.#tailCache = undefined; // tail changed
    if (this.pending.length === 0) this.#stopTimer();
  }

  /** Transport (re)connected: replay the unacked tail and resume retransmits. */
  onConnect(): void {
    this.#connected = true;
    this.flush();
    if (this.pending.length > 0) this.#startTimer();
  }

  /** Transport dropped: keep the queue (for reconnect replay), pause the timer. */
  onDisconnect(): void {
    this.#connected = false;
    this.#stopTimer();
  }

  /**
   * One retransmit tick. Exposed for deterministic testing; normally driven by
   * the internal timer.
   */
  onTick(): void {
    if (!this.#connected || this.pending.length === 0) return;
    this.flush();
  }

  /** Stop timers and drop references. Call when the provider is destroyed. */
  destroy(): void {
    this.#connected = false;
    this.#stopTimer();
    this.pending = [];
    this.#tailCache = undefined;
  }

  /** The unacked tail merged into one delta (memoized between tail changes). */
  #mergedTail(): Uint8Array {
    if (this.#tailCache === undefined) {
      const updates = this.pending.map((p) => p.update);
      this.#tailCache = updates.length === 1 ? updates[0] : this.#merge(updates);
    }
    return this.#tailCache;
  }

  #startTimer(): void {
    if (this.#timer !== undefined) return;
    this.#timer = this.#setInterval(() => this.onTick(), this.#resendInterval);
    const t = this.#timer as { unref?: () => void };
    if (t && typeof t.unref === "function") t.unref();
  }

  #stopTimer(): void {
    if (this.#timer !== undefined) this.#clearInterval(this.#timer);
    this.#timer = undefined;
  }
}
