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

type DeliveryState =
  | { phase: "paused" | "idle" | "destroyed" }
  | { phase: "sending"; stopTimer: () => void };
type DeliveryEvent = "resume" | "pause" | "queueChanged" | "destroy";

export class ReliableSync {
  #pending: Pending[] = [];
  #send: ReliableSyncOptions["send"];
  #merge: ReliableSyncOptions["merge"];
  #resendInterval: number;
  #setInterval: (handler: () => void, ms: number) => TimerHandle;
  #clearInterval: (handle: TimerHandle) => void;
  #nextSeq = 1;
  #state: DeliveryState = { phase: "paused" };
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
    if (this.#state.phase === "destroyed") return;
    this.#pending.push({ seq: this.#nextSeq++, update });
    this.#tail = undefined;
    this.#transition("queueChanged");
    this.#flush();
  }

  /**
   * Confirm delivery through `id`: every queued update with seq <= id is
   * retired. Acks come off the wire, so a malformed value or an id beyond
   * anything sent is ignored rather than trusted.
   */
  acknowledge(id: number): void {
    if (this.#state.phase === "destroyed" || !Number.isSafeInteger(id) || id < 0) return;
    const newest = this.#pending[this.#pending.length - 1];
    if (newest && id > newest.seq) return;
    this.#pending = this.#pending.filter((p) => p.seq > id);
    this.#tail = undefined;
    this.#transition("queueChanged");
  }

  /** The transport is up: replay the tail and keep retransmitting until it is acknowledged. */
  resume(): void {
    this.#transition("resume");
    this.#flush();
  }

  /** The transport is down: keep the queue, stop retransmitting. */
  pause(): void {
    this.#transition("pause");
  }

  /** Send the tail again if anything is unacknowledged. The internal timer calls this; a host with its own scheduler may too. */
  retransmit(): void {
    this.#flush();
  }

  /** Stop the timer and drop the queue. Later enqueues are ignored. */
  destroy(): void { this.#transition("destroy"); }

  #transition(event: DeliveryEvent): void {
    const current = this.#state;
    if (current.phase === "destroyed") return;
    let phase: DeliveryState["phase"];
    switch (event) {
      case "destroy": phase = "destroyed"; break;
      case "pause": phase = "paused"; break;
      case "resume": phase = this.hasPending ? "sending" : "idle"; break;
      case "queueChanged":
        if (current.phase === "paused") return;
        phase = this.hasPending ? "sending" : "idle";
        break;
    }
    if (phase === current.phase) return;
    const next: DeliveryState = phase === "sending" ? { phase, stopTimer: () => {} } : { phase };
    this.#state = next;
    if (phase === "destroyed") {
      this.#pending = [];
      this.#tail = undefined;
    }
    if (current.phase === "sending") current.stopTimer();
    if (this.#state !== next || next.phase !== "sending") return;
    let timer: TimerHandle;
    try {
      timer = this.#setInterval(() => {
        if (this.#state === next) this.#flush();
      }, this.#resendInterval);
    } catch (error) {
      if (this.#state === next) this.#state = current;
      throw error;
    }
    next.stopTimer = () => this.#clearInterval(timer);
    // An injected timer may call back before returning its handle.
    if (this.#state !== next) { next.stopTimer(); return; }
    const handle = timer as { unref?: () => void };
    if (handle && typeof handle.unref === "function") handle.unref();
  }

  // Send the whole tail as one delta, tagged with its highest seq so one ack
  // covers all of it. Nothing goes out while disconnected.
  #flush(): void {
    const current = this.#state, pending = this.#pending;
    if (current.phase !== "sending" || !pending.length) return;
    const id = pending[pending.length - 1].seq;
    const update = this.#mergedTail();
    if (this.#state === current && this.#pending === pending && pending[pending.length - 1]?.seq === id) this.#send(update, id);
  }

  #mergedTail(): Uint8Array {
    if (this.#tail === undefined) {
      const pending = this.#pending, id = pending[pending.length - 1].seq;
      const updates = pending.map((p) => p.update);
      const tail = updates.length === 1 ? updates[0] : this.#merge(updates);
      if (this.#pending === pending && pending[pending.length - 1]?.seq === id) this.#tail = tail;
      return tail;
    }
    return this.#tail;
  }

}
