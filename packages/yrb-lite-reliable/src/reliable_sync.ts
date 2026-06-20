// Transport-agnostic reliable-delivery core for the yrb-lite y-websocket
// protocol. This owns the "nuances" a provider would otherwise re-implement:
// an ack-tracked queue of unacknowledged local updates, "sync since last ack"
// (the unacked tail is sent as one MERGED, causally-complete delta so the server
// never sees an internal gap), cumulative acks, periodic retransmit with a
// "server doesn't support acks" fallback, and reconnect replay.
//
// It does NOT touch any transport, Yjs binding, or wire encoding. You inject:
//   - send(update, id):  transmit one update. `update` is the raw merged update
//                        bytes; `id` is the cumulative sequence (or undefined,
//                        post-fallback). Frame + base64 + put it on your socket.
//   - merge(updates):    merge an array of update byte-arrays into one
//                        (typically Y.mergeUpdates from yjs).
// and you drive it from your provider's lifecycle:
//   - enqueue(update)         on every local document update (not server echoes)
//   - onAck(id)               when an { ack: id } frame arrives
//   - onConnect()/onDisconnect()  on transport (re)connect / drop
//
// Awareness/presence is intentionally out of scope -- it stays fire-and-forget
// in the provider.

/** An opaque timer handle (number in browsers, Timeout in Node). */
export type TimerHandle = unknown;

export interface ReliableSyncOptions {
  /**
   * Transmit one update. `update` is the raw merged update bytes; `id` is the
   * cumulative sequence to ack against (undefined once we've fallen back).
   */
  send: (update: Uint8Array, id: number | undefined) => void;
  /** Merge an array of update byte-arrays into one (typically Y.mergeUpdates). */
  merge: (updates: Uint8Array[]) => Uint8Array;
  /** Milliseconds between retransmits of the unacked tail (default 1000). */
  resendInterval?: number;
  /**
   * Number of resends with no ack before deciding the server doesn't support
   * reliable delivery and falling back to fire-and-forget (default 8).
   */
  maxUnconfirmedResends?: number;
  /** Called once if that fallback trips. */
  onFallback?: () => void;
  /** Injectable timer hooks (default to globals); handy for tests. */
  setInterval?: (handler: () => void, ms: number) => TimerHandle;
  clearInterval?: (handle: TimerHandle) => void;
}

const DEFAULTS = { resendInterval: 1000, maxUnconfirmedResends: 8 };

interface Pending {
  seq: number;
  update: Uint8Array;
}

export class ReliableSync {
  /** False after the no-ack fallback trips; updates then go fire-and-forget. */
  reliable = true;
  /** Unacked local updates, in order. */
  pending: Pending[] = [];

  private _send: ReliableSyncOptions["send"];
  private _merge: ReliableSyncOptions["merge"];
  private resendInterval: number;
  private maxUnconfirmedResends: number;
  private _onFallback?: () => void;
  private _setInterval: (handler: () => void, ms: number) => TimerHandle;
  private _clearInterval: (handle: TimerHandle) => void;

  private nextSeq = 1;
  private everAcked = false;
  private _resendsSinceProgress = 0;
  private _connected = false;
  private _timer: TimerHandle | undefined = undefined;

  constructor(opts: ReliableSyncOptions) {
    const { send, merge, resendInterval, maxUnconfirmedResends, onFallback } = opts ?? ({} as ReliableSyncOptions);
    if (typeof send !== "function") throw new TypeError("ReliableSync requires a send(update, id) function");
    if (typeof merge !== "function") throw new TypeError("ReliableSync requires a merge(updates) function");

    this._send = send;
    this._merge = merge;
    this.resendInterval = resendInterval ?? DEFAULTS.resendInterval;
    this.maxUnconfirmedResends = maxUnconfirmedResends ?? DEFAULTS.maxUnconfirmedResends;
    this._onFallback = onFallback;
    // Injectable timer hooks make the resend loop testable; default to globals.
    this._setInterval = opts.setInterval ?? ((fn, ms) => setInterval(fn, ms));
    this._clearInterval = opts.clearInterval ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>));
  }

  /** True while there are unacknowledged local updates. */
  get hasPending(): boolean {
    return this.pending.length > 0;
  }

  /**
   * Record a local document update. While reliable, it's queued and the unacked
   * tail is flushed; once we've fallen back, it's sent fire-and-forget.
   */
  enqueue(update: Uint8Array): void {
    if (!this.reliable) {
      this._send(update, undefined);
      return;
    }
    this.pending.push({ seq: this.nextSeq++, update });
    this.flush();
  }

  /**
   * Send the whole unacked tail as one merged delta. The id is the highest seq
   * in the batch, so a single { ack } cumulatively confirms everything up to it.
   * No-op while disconnected (the tail is replayed on the next onConnect).
   */
  flush(): void {
    if (!this._connected || this.pending.length === 0) return;
    const updates = this.pending.map((p) => p.update);
    const merged = updates.length === 1 ? updates[0] : this._merge(updates);
    const id = this.pending[this.pending.length - 1].seq;
    this._send(merged, id);
  }

  /** Confirm delivery up to `id`: prune every queued update with seq <= id. */
  onAck(id: number): void {
    this.everAcked = true;
    this._resendsSinceProgress = 0;
    this.pending = this.pending.filter((p) => p.seq > id);
  }

  /** Transport (re)connected: replay the unacked tail and resume retransmits. */
  onConnect(): void {
    this._connected = true;
    this.flush();
    this._startTimer();
  }

  /** Transport dropped: keep the queue (for reconnect replay), pause the timer. */
  onDisconnect(): void {
    this._connected = false;
    this._stopTimer();
  }

  /**
   * One retransmit tick. Exposed for deterministic testing; normally driven by
   * the internal timer. If we keep resending on a live connection and never get
   * an ack, the server doesn't support reliable delivery, so fall back to
   * fire-and-forget (and stop tracking, since idempotent CRDT sync covers it).
   */
  onTick(): void {
    if (!this._connected || this.pending.length === 0) return;
    if (!this.everAcked && ++this._resendsSinceProgress > this.maxUnconfirmedResends) {
      this.reliable = false;
      this.pending = [];
      this._stopTimer();
      this._onFallback?.();
      return;
    }
    this.flush();
  }

  /** Stop timers and drop references. Call when the provider is destroyed. */
  destroy(): void {
    this._stopTimer();
    this.pending = [];
  }

  private _startTimer(): void {
    if (this._timer !== undefined || !this.reliable) return;
    this._timer = this._setInterval(() => this.onTick(), this.resendInterval);
    const t = this._timer as { unref?: () => void };
    if (t && typeof t.unref === "function") t.unref();
  }

  private _stopTimer(): void {
    if (this._timer !== undefined) this._clearInterval(this._timer);
    this._timer = undefined;
  }
}
