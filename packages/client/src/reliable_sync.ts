// Transport-agnostic reliable delivery for the yrby y-websocket protocol.
//
// Every local update joins an ordered queue with a sequence number and stays
// there until the server acknowledges it. While the transport is up, the whole
// unacknowledged tail goes out as one merged, causally complete delta (so the
// server never sees an internal gap), and goes out again on a timer until an
// ack arrives. Acks are cumulative: one { ack: n } retires everything up to n.
// While the transport is down nothing is sent and nothing is dropped; the tail
// is replayed when it comes back.
//
// It touches neither the transport nor Yjs. Inject two functions: send(update,
// id) transmits one delta plus the sequence id to acknowledge against, and
// merge(updates) folds update byte arrays into one (usually Y.mergeUpdates).
// Drive it from the transport lifecycle: enqueue(update) on each local edit,
// acknowledge(id) when an { ack: id } envelope arrives, resume() when the
// transport connects, pause() when it drops.
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

/** One queued update and the sequence number an ack must reach to retire it. */
export interface Pending {
  readonly seq: number;
  readonly update: Uint8Array;
}

const DEFAULT_RESEND_INTERVAL = 1000;

export class ReliableSync {
  #pending: Pending[] = [];
  #send: ReliableSyncOptions["send"];
  #merge: ReliableSyncOptions["merge"];
  #resendInterval: number;
  #setInterval: (handler: () => void, ms: number) => TimerHandle;
  #clearInterval: (handle: TimerHandle) => void;
  #nextSeq = 1;
  #connected = false;
  #destroyed = false;
  #timer: TimerHandle | undefined;
  // The queue merged into one delta, memoized until the queue changes, so a
  // retransmit tick does not re-merge everything every second.
  #tail: Uint8Array | undefined;

  constructor(opts: ReliableSyncOptions) {
    const { send, merge, resendInterval, setInterval: setTimer, clearInterval: clearTimer } =
      opts ?? ({} as ReliableSyncOptions);
    if (typeof send !== "function") throw new TypeError("ReliableSync requires a send(update, id) function");
    if (typeof merge !== "function") throw new TypeError("ReliableSync requires a merge(updates) function");
    const interval = resendInterval ?? DEFAULT_RESEND_INTERVAL;
    if (!Number.isFinite(interval) || interval <= 0) {
      throw new TypeError("ReliableSync resendInterval must be a positive number");
    }
    this.#send = send;
    this.#merge = merge;
    this.#resendInterval = interval;
    this.#setInterval = setTimer ?? ((fn, ms) => setInterval(fn, ms));
    this.#clearInterval = clearTimer ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>));
  }

  /** Unacknowledged local updates, oldest first. The queue changes only through enqueue and acknowledge. */
  get pending(): readonly Pending[] {
    return this.#pending;
  }

  /** True while there are unacknowledged local updates. */
  get hasPending(): boolean {
    return this.#pending.length > 0;
  }

  /** Queue a local update and, while connected, send the tail. Ignored after destroy(). */
  enqueue(update: Uint8Array): void {
    if (this.#destroyed) return;
    this.#pending.push({ seq: this.#nextSeq++, update });
    this.#tail = undefined;
    if (!this.#connected) return;
    this.#startTimer();
    this.#flush();
  }

  /**
   * Confirm delivery through `id`: every queued update with seq <= id is
   * retired. Acks come off the wire, so a malformed value or an id beyond
   * anything sent is ignored rather than trusted.
   */
  acknowledge(id: number): void {
    if (!Number.isSafeInteger(id) || id < 0) return;
    const newest = this.#pending[this.#pending.length - 1];
    if (newest && id > newest.seq) return;
    this.#pending = this.#pending.filter((p) => p.seq > id);
    this.#tail = undefined;
    if (this.#pending.length === 0) this.#stopTimer();
  }

  /** The transport is up: replay the tail and keep retransmitting until it is acknowledged. */
  resume(): void {
    this.#connected = true;
    this.#flush();
    if (this.#pending.length > 0) this.#startTimer();
  }

  /** The transport is down: keep the queue, stop retransmitting. */
  pause(): void {
    this.#connected = false;
    this.#stopTimer();
  }

  /** Send the tail again if anything is unacknowledged. The internal timer calls this; a host with its own scheduler may too. */
  retransmit(): void {
    this.#flush();
  }

  /** Stop the timer and drop the queue. Later enqueues are ignored. */
  destroy(): void {
    this.#destroyed = true;
    this.#connected = false;
    this.#stopTimer();
    this.#pending = [];
    this.#tail = undefined;
  }

  // Send the whole tail as one delta, tagged with its highest seq so one ack
  // covers all of it. Nothing goes out while disconnected.
  #flush(): void {
    if (!this.#connected || this.#pending.length === 0) return;
    this.#send(this.#mergedTail(), this.#pending[this.#pending.length - 1].seq);
  }

  #mergedTail(): Uint8Array {
    if (this.#tail === undefined) {
      const updates = this.#pending.map((p) => p.update);
      this.#tail = updates.length === 1 ? updates[0] : this.#merge(updates);
    }
    return this.#tail;
  }

  #startTimer(): void {
    if (this.#timer !== undefined) return;
    this.#timer = this.#setInterval(() => this.retransmit(), this.#resendInterval);
    const t = this.#timer as { unref?: () => void };
    if (t && typeof t.unref === "function") t.unref(); // never hold a Node process open
  }

  #stopTimer(): void {
    if (this.#timer !== undefined) this.#clearInterval(this.#timer);
    this.#timer = undefined;
  }
}
