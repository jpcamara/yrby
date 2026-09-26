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

// "live" means the transport is up. The retransmit timer runs exactly while
// delivery is live and something is unacknowledged.
type Phase = "paused" | "live" | "destroyed";
type Timer = { stop: () => void };

export class ReliableSync {
  #pending: Pending[] = [];
  #send: ReliableSyncOptions["send"];
  #merge: ReliableSyncOptions["merge"];
  #resendInterval: number;
  #setInterval: (handler: () => void, ms: number) => TimerHandle;
  #clearInterval: (handle: TimerHandle) => void;
  #nextSeq = 1;
  #phase: Phase = "paused";
  #timer: Timer | undefined;
  // Bumped on every queue or phase change. Injected send/merge/timer functions
  // can call back into this object, so work started before such a call checks
  // afterwards whether anything moved underneath it.
  #version = 0;
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

  /** A snapshot of unacknowledged local updates, oldest first. Editing it does not change the queue. */
  get pending(): readonly Pending[] {
    return this.#pending.map(({ seq, update }) => ({ seq, update: update.slice() }));
  }

  /** True while there are unacknowledged local updates. */
  get hasPending(): boolean {
    return this.#pending.length > 0;
  }

  /** Queue a local update and, while connected, send the tail. Ignored after destroy(). */
  enqueue(update: Uint8Array): void {
    if (this.#phase === "destroyed") return;
    this.#pending.push({ seq: this.#nextSeq++, update: new Uint8Array(update) });
    this.#queueChanged();
    this.#flush();
  }

  /**
   * Confirm delivery through `id`: every queued update with seq <= id is
   * retired. Acks come off the wire, so a malformed value or an id beyond
   * anything sent is ignored rather than trusted.
   */
  acknowledge(id: number): void {
    if (this.#phase === "destroyed" || !Number.isSafeInteger(id) || id < 0) return;
    const newest = this.#pending.at(-1);
    if (newest && id > newest.seq) return;
    this.#pending = this.#pending.filter((p) => p.seq > id);
    this.#queueChanged();
  }

  /** The transport is up: replay the tail and keep retransmitting until it is acknowledged. */
  resume(): void {
    if (this.#phase === "destroyed") return;
    this.#phase = "live";
    this.#version++;
    this.#updateTimer();
    this.#flush();
  }

  /** The transport is down: keep the queue, stop retransmitting. */
  pause(): void {
    if (this.#phase === "destroyed") return;
    this.#phase = "paused";
    this.#version++;
    this.#updateTimer();
  }

  /** Send the tail again if anything is unacknowledged. The internal timer calls this; a host with its own scheduler may too. */
  retransmit(): void {
    this.#flush();
  }

  /** Stop the timer and drop the queue. Later enqueues are ignored. */
  destroy(): void {
    if (this.#phase === "destroyed") return;
    this.#phase = "destroyed";
    this.#pending = [];
    this.#queueChanged();
  }

  #queueChanged(): void {
    this.#version++;
    this.#tail = undefined;
    this.#updateTimer();
  }

  // Start or stop the retransmit timer so it runs exactly while live with work queued.
  #updateTimer(): void {
    const wanted = this.#phase === "live" && this.hasPending;
    if (wanted === (this.#timer !== undefined)) return;
    if (!wanted) {
      const timer = this.#timer!;
      this.#timer = undefined;
      timer.stop();
      return;
    }
    // Installed before setInterval so a tick during that call sees its own
    // timer. Stopping it before the handle exists does nothing; the check
    // after setInterval returns cancels the real handle.
    const timer: Timer = this.#timer = { stop: () => {} };
    let handle: TimerHandle;
    try {
      handle = this.#setInterval(() => { if (this.#timer === timer) this.#flush(); }, this.#resendInterval);
    } catch (error) {
      // Nothing is lost: the next resume or queue change tries again.
      if (this.#timer === timer) this.#timer = undefined;
      throw error;
    }
    timer.stop = () => this.#clearInterval(handle);
    // An injected timer may tick before returning its handle, and that tick
    // can pause or drain delivery.
    if (this.#timer !== timer) { timer.stop(); return; }
    (handle as { unref?: () => void } | null)?.unref?.();
  }

  // Send the whole tail as one delta, tagged with its highest seq so one ack
  // covers all of it. Nothing goes out while disconnected.
  #flush(): void {
    if (this.#phase !== "live" || !this.#pending.length) return;
    if (this.#tail === undefined) {
      const version = this.#version;
      const updates = this.#pending.map((p) => p.update);
      const tail = updates.length === 1 ? updates[0] : this.#merge(updates);
      // merge may have changed the queue, paused, or already sent through a nested resume.
      if (this.#version !== version) return;
      this.#tail = tail;
    }
    this.#send(this.#tail, this.#pending.at(-1)!.seq);
  }
}
