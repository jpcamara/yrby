// src/reliable_sync.ts
var DEFAULT_RESEND_INTERVAL = 1e3;
var ReliableSync = class {
  #pending = [];
  #send;
  #merge;
  #resendInterval;
  #setInterval;
  #clearInterval;
  #nextSeq = 1;
  #phase = "paused";
  #timer;
  // Incremented on every queue or phase change. Injected send/merge/timer
  // functions can call back into this object, so code that calls one compares
  // the version afterwards to detect changes made during the call.
  #version = 0;
  // The queue merged into one delta. It's memoized until the queue changes so
  // retransmit ticks don't re-merge the whole queue every second.
  #tail;
  constructor(opts) {
    const { send, merge, resendInterval, setInterval: setTimer, clearInterval: clearTimer } = opts ?? {};
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
    this.#clearInterval = clearTimer ?? ((h) => clearInterval(h));
  }
  /** A snapshot of unacknowledged local updates, oldest first. Editing it does not change the queue. */
  get pending() {
    return this.#pending.map(({ seq, update }) => ({ seq, update: update.slice() }));
  }
  /** True while there are unacknowledged local updates. */
  get hasPending() {
    return this.#pending.length > 0;
  }
  /** Queue a local update and, while connected, send the tail. Ignored after destroy(). */
  enqueue(update) {
    if (this.#phase === "destroyed") return;
    this.#pending.push({ seq: this.#nextSeq++, update: new Uint8Array(update) });
    this.#queueChanged();
    this.#flush();
  }
  /**
   * Confirm delivery through `id`, removing every queued update with
   * seq <= id. Acks come off the wire, so ignore a malformed value or an id
   * beyond anything sent.
   */
  acknowledge(id) {
    if (this.#phase === "destroyed" || !Number.isSafeInteger(id) || id < 0) return;
    const newest = this.#pending.at(-1);
    if (newest && id > newest.seq) return;
    this.#pending = this.#pending.filter((p) => p.seq > id);
    this.#queueChanged();
  }
  /** Call when the transport is up. Replays the tail and keeps retransmitting until it is acknowledged. */
  resume() {
    if (this.#phase === "destroyed") return;
    this.#phase = "live";
    this.#version++;
    this.#updateTimer();
    this.#flush();
  }
  /** Call when the transport is down. Keeps the queue and stops retransmitting. */
  pause() {
    if (this.#phase === "destroyed") return;
    this.#phase = "paused";
    this.#version++;
    this.#updateTimer();
  }
  /** Send the tail again if anything is unacknowledged. The internal timer calls this, and a host with its own scheduler can too. */
  retransmit() {
    this.#flush();
  }
  /** Stop the timer and drop the queue. Later enqueues are ignored. */
  destroy() {
    if (this.#phase === "destroyed") return;
    this.#phase = "destroyed";
    this.#pending = [];
    this.#queueChanged();
  }
  #queueChanged() {
    this.#version++;
    this.#tail = void 0;
    this.#updateTimer();
  }
  // Start or stop the retransmit timer so it runs only while live with work queued.
  #updateTimer() {
    const wanted = this.#phase === "live" && this.hasPending;
    if (wanted === (this.#timer !== void 0)) return;
    if (!wanted) {
      const timer2 = this.#timer;
      this.#timer = void 0;
      timer2.stop();
      return;
    }
    const timer = this.#timer = { stop: () => {
    } };
    let handle;
    try {
      handle = this.#setInterval(() => {
        if (this.#timer === timer) this.#flush();
      }, this.#resendInterval);
    } catch (error) {
      if (this.#timer === timer) this.#timer = void 0;
      throw error;
    }
    timer.stop = () => this.#clearInterval(handle);
    if (this.#timer !== timer) {
      timer.stop();
      return;
    }
    handle?.unref?.();
  }
  // Send the whole tail as one delta, tagged with its highest seq so one ack
  // covers all of it. Does nothing while disconnected.
  #flush() {
    if (this.#phase !== "live" || !this.#pending.length) return;
    if (this.#tail === void 0) {
      const version = this.#version;
      const updates = this.#pending.map((p) => p.update);
      const tail = updates.length === 1 ? updates[0] : this.#merge(updates);
      if (this.#version !== version) return;
      this.#tail = tail;
    }
    this.#send(this.#tail, this.#pending.at(-1).seq);
  }
};

// src/y_protocol_session.ts
import { mergeUpdates, applyUpdate as applyUpdate2 } from "yjs";

// node_modules/lib0/math.js
var floor = Math.floor;
var min = (a, b) => a < b ? a : b;
var max = (a, b) => a > b ? a : b;
var isNaN = Number.isNaN;

// node_modules/lib0/binary.js
var BIT8 = 128;
var BIT18 = 1 << 17;
var BIT19 = 1 << 18;
var BIT20 = 1 << 19;
var BIT21 = 1 << 20;
var BIT22 = 1 << 21;
var BIT23 = 1 << 22;
var BIT24 = 1 << 23;
var BIT25 = 1 << 24;
var BIT26 = 1 << 25;
var BIT27 = 1 << 26;
var BIT28 = 1 << 27;
var BIT29 = 1 << 28;
var BIT30 = 1 << 29;
var BIT31 = 1 << 30;
var BIT32 = 1 << 31;
var BITS7 = 127;
var BITS17 = BIT18 - 1;
var BITS18 = BIT19 - 1;
var BITS19 = BIT20 - 1;
var BITS20 = BIT21 - 1;
var BITS21 = BIT22 - 1;
var BITS22 = BIT23 - 1;
var BITS23 = BIT24 - 1;
var BITS24 = BIT25 - 1;
var BITS25 = BIT26 - 1;
var BITS26 = BIT27 - 1;
var BITS27 = BIT28 - 1;
var BITS28 = BIT29 - 1;
var BITS29 = BIT30 - 1;
var BITS30 = BIT31 - 1;

// node_modules/lib0/number.js
var MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER;
var MIN_SAFE_INTEGER = Number.MIN_SAFE_INTEGER;
var LOWEST_INT32 = 1 << 31;
var isInteger = Number.isInteger || ((num) => typeof num === "number" && isFinite(num) && floor(num) === num);
var isNaN2 = Number.isNaN;
var parseInt = Number.parseInt;

// node_modules/lib0/set.js
var create = () => /* @__PURE__ */ new Set();

// node_modules/lib0/array.js
var from = Array.from;

// node_modules/lib0/string.js
var fromCharCode = String.fromCharCode;
var fromCodePoint = String.fromCodePoint;
var MAX_UTF16_CHARACTER = fromCharCode(65535);
var _encodeUtf8Polyfill = (str) => {
  const encodedString = unescape(encodeURIComponent(str));
  const len = encodedString.length;
  const buf = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    buf[i] = /** @type {number} */
    encodedString.codePointAt(i);
  }
  return buf;
};
var utf8TextEncoder = (
  /** @type {TextEncoder} */
  typeof TextEncoder !== "undefined" ? new TextEncoder() : null
);
var _encodeUtf8Native = (str) => utf8TextEncoder.encode(str);
var encodeUtf8 = utf8TextEncoder ? _encodeUtf8Native : _encodeUtf8Polyfill;
var utf8TextDecoder = typeof TextDecoder === "undefined" ? null : new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
if (utf8TextDecoder && utf8TextDecoder.decode(new Uint8Array()).length === 1) {
  utf8TextDecoder = null;
}

// node_modules/lib0/encoding.js
var Encoder = class {
  constructor() {
    this.cpos = 0;
    this.cbuf = new Uint8Array(100);
    this.bufs = [];
  }
};
var createEncoder = () => new Encoder();
var length = (encoder) => {
  let len = encoder.cpos;
  for (let i = 0; i < encoder.bufs.length; i++) {
    len += encoder.bufs[i].length;
  }
  return len;
};
var toUint8Array = (encoder) => {
  const uint8arr = new Uint8Array(length(encoder));
  let curPos = 0;
  for (let i = 0; i < encoder.bufs.length; i++) {
    const d = encoder.bufs[i];
    uint8arr.set(d, curPos);
    curPos += d.length;
  }
  uint8arr.set(new Uint8Array(encoder.cbuf.buffer, 0, encoder.cpos), curPos);
  return uint8arr;
};
var write = (encoder, num) => {
  const bufferLen = encoder.cbuf.length;
  if (encoder.cpos === bufferLen) {
    encoder.bufs.push(encoder.cbuf);
    encoder.cbuf = new Uint8Array(bufferLen * 2);
    encoder.cpos = 0;
  }
  encoder.cbuf[encoder.cpos++] = num;
};
var writeVarUint = (encoder, num) => {
  while (num > BITS7) {
    write(encoder, BIT8 | BITS7 & num);
    num = floor(num / 128);
  }
  write(encoder, BITS7 & num);
};
var _strBuffer = new Uint8Array(3e4);
var _maxStrBSize = _strBuffer.length / 3;
var _writeVarStringNative = (encoder, str) => {
  if (str.length < _maxStrBSize) {
    const written = utf8TextEncoder.encodeInto(str, _strBuffer).written || 0;
    writeVarUint(encoder, written);
    for (let i = 0; i < written; i++) {
      write(encoder, _strBuffer[i]);
    }
  } else {
    writeVarUint8Array(encoder, encodeUtf8(str));
  }
};
var _writeVarStringPolyfill = (encoder, str) => {
  const encodedString = unescape(encodeURIComponent(str));
  const len = encodedString.length;
  writeVarUint(encoder, len);
  for (let i = 0; i < len; i++) {
    write(
      encoder,
      /** @type {number} */
      encodedString.codePointAt(i)
    );
  }
};
var writeVarString = utf8TextEncoder && /** @type {any} */
utf8TextEncoder.encodeInto ? _writeVarStringNative : _writeVarStringPolyfill;
var writeUint8Array = (encoder, uint8Array) => {
  const bufferLen = encoder.cbuf.length;
  const cpos = encoder.cpos;
  const leftCopyLen = min(bufferLen - cpos, uint8Array.length);
  const rightCopyLen = uint8Array.length - leftCopyLen;
  encoder.cbuf.set(uint8Array.subarray(0, leftCopyLen), cpos);
  encoder.cpos += leftCopyLen;
  if (rightCopyLen > 0) {
    encoder.bufs.push(encoder.cbuf);
    encoder.cbuf = new Uint8Array(max(bufferLen * 2, rightCopyLen));
    encoder.cbuf.set(uint8Array.subarray(leftCopyLen));
    encoder.cpos = rightCopyLen;
  }
};
var writeVarUint8Array = (encoder, uint8Array) => {
  writeVarUint(encoder, uint8Array.byteLength);
  writeUint8Array(encoder, uint8Array);
};
var floatTestBed = new DataView(new ArrayBuffer(4));

// node_modules/lib0/error.js
var create2 = (s) => new Error(s);

// node_modules/lib0/decoding.js
var errorUnexpectedEndOfArray = create2("Unexpected end of array");
var errorIntegerOutOfRange = create2("Integer out of Range");
var Decoder = class {
  /**
   * @param {Uint8Array<Buf>} uint8Array Binary data to decode
   */
  constructor(uint8Array) {
    this.arr = uint8Array;
    this.pos = 0;
  }
};
var createDecoder = (uint8Array) => new Decoder(uint8Array);
var hasContent = (decoder) => decoder.pos !== decoder.arr.length;
var readUint8Array = (decoder, len) => {
  const view = new Uint8Array(decoder.arr.buffer, decoder.pos + decoder.arr.byteOffset, len);
  decoder.pos += len;
  return view;
};
var readVarUint8Array = (decoder) => readUint8Array(decoder, readVarUint(decoder));
var readUint8 = (decoder) => decoder.arr[decoder.pos++];
var readVarUint = (decoder) => {
  let num = 0;
  let mult = 1;
  const len = decoder.arr.length;
  while (decoder.pos < len) {
    const r = decoder.arr[decoder.pos++];
    num = num + (r & BITS7) * mult;
    mult *= 128;
    if (r < BIT8) {
      return num;
    }
    if (num > MAX_SAFE_INTEGER) {
      throw errorIntegerOutOfRange;
    }
  }
  throw errorUnexpectedEndOfArray;
};
var _readVarStringPolyfill = (decoder) => {
  let remainingLen = readVarUint(decoder);
  if (remainingLen === 0) {
    return "";
  } else {
    let encodedString = String.fromCodePoint(readUint8(decoder));
    if (--remainingLen < 100) {
      while (remainingLen--) {
        encodedString += String.fromCodePoint(readUint8(decoder));
      }
    } else {
      while (remainingLen > 0) {
        const nextLen = remainingLen < 1e4 ? remainingLen : 1e4;
        const bytes = decoder.arr.subarray(decoder.pos, decoder.pos + nextLen);
        decoder.pos += nextLen;
        encodedString += String.fromCodePoint.apply(
          null,
          /** @type {any} */
          bytes
        );
        remainingLen -= nextLen;
      }
    }
    return decodeURIComponent(escape(encodedString));
  }
};
var _readVarStringNative = (decoder) => (
  /** @type any */
  utf8TextDecoder.decode(readVarUint8Array(decoder))
);
var readVarString = utf8TextDecoder ? _readVarStringNative : _readVarStringPolyfill;

// node_modules/y-protocols/sync.js
import * as Y from "yjs";
var messageYjsSyncStep1 = 0;
var messageYjsSyncStep2 = 1;
var messageYjsUpdate = 2;
var writeSyncStep1 = (encoder, doc) => {
  writeVarUint(encoder, messageYjsSyncStep1);
  const sv = Y.encodeStateVector(doc);
  writeVarUint8Array(encoder, sv);
};
var writeSyncStep2 = (encoder, doc, encodedStateVector) => {
  writeVarUint(encoder, messageYjsSyncStep2);
  writeVarUint8Array(encoder, Y.encodeStateAsUpdate(doc, encodedStateVector));
};
var readSyncStep1 = (decoder, encoder, doc) => writeSyncStep2(encoder, doc, readVarUint8Array(decoder));
var readSyncStep2 = (decoder, doc, transactionOrigin, errorHandler) => {
  try {
    Y.applyUpdate(doc, readVarUint8Array(decoder), transactionOrigin);
  } catch (error) {
    if (errorHandler != null) errorHandler(
      /** @type {Error} */
      error
    );
    console.error("Caught error while handling a Yjs update", error);
  }
};
var writeUpdate = (encoder, update) => {
  writeVarUint(encoder, messageYjsUpdate);
  writeVarUint8Array(encoder, update);
};
var readUpdate = readSyncStep2;
var readSyncMessage = (decoder, encoder, doc, transactionOrigin, errorHandler) => {
  const messageType = readVarUint(decoder);
  switch (messageType) {
    case messageYjsSyncStep1:
      readSyncStep1(decoder, encoder, doc);
      break;
    case messageYjsSyncStep2:
      readSyncStep2(decoder, doc, transactionOrigin, errorHandler);
      break;
    case messageYjsUpdate:
      readUpdate(decoder, doc, transactionOrigin, errorHandler);
      break;
    default:
      throw new Error("Unknown message type");
  }
  return messageType;
};

// node_modules/lib0/time.js
var getUnixTime = Date.now;

// node_modules/lib0/map.js
var create3 = () => /* @__PURE__ */ new Map();
var setIfUndefined = (map, key, createT) => {
  let set = map.get(key);
  if (set === void 0) {
    map.set(key, set = createT());
  }
  return set;
};

// node_modules/lib0/observable.js
var Observable = class {
  constructor() {
    this._observers = create3();
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  on(name, f) {
    setIfUndefined(this._observers, name, create).add(f);
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  once(name, f) {
    const _f = (...args) => {
      this.off(name, _f);
      f(...args);
    };
    this.on(name, _f);
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  off(name, f) {
    const observers = this._observers.get(name);
    if (observers !== void 0) {
      observers.delete(f);
      if (observers.size === 0) {
        this._observers.delete(name);
      }
    }
  }
  /**
   * Emit a named event. All registered event listeners that listen to the
   * specified name will receive the event.
   *
   * @todo This should catch exceptions
   *
   * @param {N} name The event name.
   * @param {Array<any>} args The arguments that are applied to the event listener.
   */
  emit(name, args) {
    return from((this._observers.get(name) || create3()).values()).forEach((f) => f(...args));
  }
  destroy() {
    this._observers = create3();
  }
};

// node_modules/lib0/trait/equality.js
var EqualityTraitSymbol = Symbol("Equality");

// node_modules/lib0/object.js
var keys = Object.keys;
var size = (obj) => keys(obj).length;
var hasProperty = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

// node_modules/lib0/function.js
var equalityDeep = (a, b) => {
  if (a === b) {
    return true;
  }
  if (a == null || b == null || a.constructor !== b.constructor && (a.constructor || Object) !== (b.constructor || Object)) {
    return false;
  }
  if (a[EqualityTraitSymbol] != null) {
    return a[EqualityTraitSymbol](b);
  }
  switch (a.constructor) {
    case ArrayBuffer:
      a = new Uint8Array(a);
      b = new Uint8Array(b);
    // eslint-disable-next-line no-fallthrough
    case Uint8Array: {
      if (a.byteLength !== b.byteLength) {
        return false;
      }
      for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) {
          return false;
        }
      }
      break;
    }
    case Set: {
      if (a.size !== b.size) {
        return false;
      }
      for (const value of a) {
        if (!b.has(value)) {
          return false;
        }
      }
      break;
    }
    case Map: {
      if (a.size !== b.size) {
        return false;
      }
      for (const key of a.keys()) {
        if (!b.has(key) || !equalityDeep(a.get(key), b.get(key))) {
          return false;
        }
      }
      break;
    }
    case void 0:
    case Object:
      if (size(a) !== size(b)) {
        return false;
      }
      for (const key in a) {
        if (!hasProperty(a, key) || !equalityDeep(a[key], b[key])) {
          return false;
        }
      }
      break;
    case Array:
      if (a.length !== b.length) {
        return false;
      }
      for (let i = 0; i < a.length; i++) {
        if (!equalityDeep(a[i], b[i])) {
          return false;
        }
      }
      break;
    default:
      return false;
  }
  return true;
};

// node_modules/y-protocols/awareness.js
import * as Y2 from "yjs";
var outdatedTimeout = 3e4;
var Awareness = class extends Observable {
  /**
   * @param {Y.Doc} doc
   */
  constructor(doc) {
    super();
    this.doc = doc;
    this.clientID = doc.clientID;
    this.states = /* @__PURE__ */ new Map();
    this.meta = /* @__PURE__ */ new Map();
    this._checkInterval = /** @type {any} */
    setInterval(() => {
      const now = getUnixTime();
      if (this.getLocalState() !== null && outdatedTimeout / 2 <= now - /** @type {{lastUpdated:number}} */
      this.meta.get(this.clientID).lastUpdated) {
        this.setLocalState(this.getLocalState());
      }
      const remove = [];
      this.meta.forEach((meta, clientid) => {
        if (clientid !== this.clientID && outdatedTimeout <= now - meta.lastUpdated && this.states.has(clientid)) {
          remove.push(clientid);
        }
      });
      if (remove.length > 0) {
        removeAwarenessStates(this, remove, "timeout");
      }
    }, floor(outdatedTimeout / 10));
    doc.on("destroy", () => {
      this.destroy();
    });
    this.setLocalState({});
  }
  destroy() {
    this.emit("destroy", [this]);
    this.setLocalState(null);
    super.destroy();
    clearInterval(this._checkInterval);
  }
  /**
   * @return {Object<string,any>|null}
   */
  getLocalState() {
    return this.states.get(this.clientID) || null;
  }
  /**
   * @param {Object<string,any>|null} state
   */
  setLocalState(state) {
    const clientID = this.clientID;
    const currLocalMeta = this.meta.get(clientID);
    const clock = currLocalMeta === void 0 ? 0 : currLocalMeta.clock + 1;
    const prevState = this.states.get(clientID);
    if (state === null) {
      this.states.delete(clientID);
    } else {
      this.states.set(clientID, state);
    }
    this.meta.set(clientID, {
      clock,
      lastUpdated: getUnixTime()
    });
    const added = [];
    const updated = [];
    const filteredUpdated = [];
    const removed = [];
    if (state === null) {
      removed.push(clientID);
    } else if (prevState == null) {
      if (state != null) {
        added.push(clientID);
      }
    } else {
      updated.push(clientID);
      if (!equalityDeep(prevState, state)) {
        filteredUpdated.push(clientID);
      }
    }
    if (added.length > 0 || filteredUpdated.length > 0 || removed.length > 0) {
      this.emit("change", [{ added, updated: filteredUpdated, removed }, "local"]);
    }
    this.emit("update", [{ added, updated, removed }, "local"]);
  }
  /**
   * @param {string} field
   * @param {any} value
   */
  setLocalStateField(field, value) {
    const state = this.getLocalState();
    if (state !== null) {
      this.setLocalState({
        ...state,
        [field]: value
      });
    }
  }
  /**
   * @return {Map<number,Object<string,any>>}
   */
  getStates() {
    return this.states;
  }
};
var removeAwarenessStates = (awareness, clients, origin) => {
  const removed = [];
  for (let i = 0; i < clients.length; i++) {
    const clientID = clients[i];
    if (awareness.states.has(clientID)) {
      awareness.states.delete(clientID);
      if (clientID === awareness.clientID) {
        const curMeta = (
          /** @type {MetaClientState} */
          awareness.meta.get(clientID)
        );
        awareness.meta.set(clientID, {
          clock: curMeta.clock + 1,
          lastUpdated: getUnixTime()
        });
      }
      removed.push(clientID);
    }
  }
  if (removed.length > 0) {
    awareness.emit("change", [{ added: [], updated: [], removed }, origin]);
    awareness.emit("update", [{ added: [], updated: [], removed }, origin]);
  }
};
var encodeAwarenessUpdate = (awareness, clients, states = awareness.states) => {
  const len = clients.length;
  const encoder = createEncoder();
  writeVarUint(encoder, len);
  for (let i = 0; i < len; i++) {
    const clientID = clients[i];
    const state = states.get(clientID) || null;
    const clock = (
      /** @type {MetaClientState} */
      awareness.meta.get(clientID).clock
    );
    writeVarUint(encoder, clientID);
    writeVarUint(encoder, clock);
    writeVarString(encoder, JSON.stringify(state));
  }
  return toUint8Array(encoder);
};
var applyAwarenessUpdate = (awareness, update, origin) => {
  const decoder = createDecoder(update);
  const timestamp = getUnixTime();
  const added = [];
  const updated = [];
  const filteredUpdated = [];
  const removed = [];
  const len = readVarUint(decoder);
  for (let i = 0; i < len; i++) {
    const clientID = readVarUint(decoder);
    let clock = readVarUint(decoder);
    const state = JSON.parse(readVarString(decoder));
    const clientMeta = awareness.meta.get(clientID);
    const prevState = awareness.states.get(clientID);
    const currClock = clientMeta === void 0 ? 0 : clientMeta.clock;
    if (currClock < clock || currClock === clock && state === null && awareness.states.has(clientID)) {
      if (state === null) {
        if (clientID === awareness.clientID && awareness.getLocalState() != null) {
          clock++;
        } else {
          awareness.states.delete(clientID);
        }
      } else {
        awareness.states.set(clientID, state);
      }
      awareness.meta.set(clientID, {
        clock,
        lastUpdated: timestamp
      });
      if (clientMeta === void 0 && state !== null) {
        added.push(clientID);
      } else if (clientMeta !== void 0 && state === null) {
        removed.push(clientID);
      } else if (state !== null) {
        if (!equalityDeep(state, prevState)) {
          filteredUpdated.push(clientID);
        }
        updated.push(clientID);
      }
    }
  }
  if (added.length > 0 || filteredUpdated.length > 0 || removed.length > 0) {
    awareness.emit("change", [{
      added,
      updated: filteredUpdated,
      removed
    }, origin]);
  }
  if (added.length > 0 || updated.length > 0 || removed.length > 0) {
    awareness.emit("update", [{
      added,
      updated,
      removed
    }, origin]);
  }
};

// src/y_protocol_session.ts
var MessageType = { Sync: 0, Awareness: 1 };
var YProtocolSession = class {
  doc;
  awareness;
  #send;
  #onError;
  #state = { phase: "unsynced", cycle: {} };
  #delivery;
  #onDocUpdate;
  #onAwarenessUpdate;
  constructor(doc, opts) {
    const { send, awareness = null, resendInterval, onError, setInterval: setTimer, clearInterval: clearTimer } = opts ?? {};
    if (!doc) throw new TypeError("YProtocolSession requires a Y.Doc");
    if (typeof send !== "function") throw new TypeError("YProtocolSession requires a send(frame, id) function");
    this.doc = doc;
    this.awareness = awareness;
    this.#send = send;
    this.#onError = onError ?? ((error, context) => console.warn(`[yrby] ${context}:`, error));
    this.#delivery = new ReliableSync({
      merge: mergeUpdates,
      send: (update, id) => this.#send(this.#frameUpdate(update), id),
      resendInterval,
      setInterval: setTimer,
      clearInterval: clearTimer
    });
    this.#onDocUpdate = (update, origin) => {
      if (origin === this) return;
      this.#delivery.enqueue(update);
    };
    this.doc.on("update", this.#onDocUpdate);
    if (this.awareness) {
      this.#onAwarenessUpdate = ({ added, updated, removed }, origin) => {
        if (origin === this || this.#state.phase === "destroyed") return;
        const changed = added.concat(updated, removed);
        this.#send(this.#frameAwareness(changed), void 0);
      };
      this.awareness.on("update", this.#onAwarenessUpdate);
    }
  }
  /** True once we've received the server's SyncStep2 (the document is caught up). */
  get synced() {
    return this.#state.phase === "synced";
  }
  /** True while there are unacknowledged local document updates in flight. */
  get hasPending() {
    return this.#delivery.hasPending;
  }
  /** Call when the transport is up. Sends the opening handshake, re-announces presence, and replays the unacked tail. */
  resume() {
    if (this.#state.phase === "destroyed") return;
    const cycle = {};
    this.#state = { phase: "unsynced", cycle };
    this.#send(this.#frameSyncStep1(), void 0);
    if (!this.#current(cycle)) return;
    if (this.awareness && this.awareness.getLocalState() !== null) {
      this.#send(this.#frameAwareness([this.doc.clientID]), void 0);
    }
    if (this.#current(cycle)) this.#delivery.resume();
  }
  /** Call when the transport is down. Keeps the queue, stops retransmits, and clears peers' presence. */
  pause() {
    if (this.#state.phase === "destroyed") return;
    this.#state = { phase: "unsynced", cycle: {} };
    this.#delivery.pause();
    if (this.awareness) {
      const remote = [...this.awareness.getStates().keys()].filter((c) => c !== this.doc.clientID);
      if (remote.length) removeAwarenessStates(this.awareness, remote, this);
    }
  }
  /**
   * Broadcast that our local presence is gone (sets local state to null, which
   * emits a removal awareness frame through `send`). Call this while the
   * transport is still live so peers drop our cursor immediately instead of
   * waiting for the awareness timeout. A no-op when there's no local state.
   */
  removeLocalAwareness() {
    if (this.#state.phase !== "destroyed" && this.awareness && this.awareness.getLocalState() !== null) {
      this.awareness.setLocalState(null);
    }
  }
  /** A reliable-delivery `{ ack: id }` envelope arrived. */
  acknowledge(id) {
    this.#delivery.acknowledge(id);
  }
  /**
   * Apply an update without treating it as a local edit, so it isn't queued for
   * re-delivery to the server. Use it for bootstrap/restore: initial state loaded
   * over HTTP, a server snapshot, an import. These are bytes the server already
   * has.
   *
   * The session re-sends any doc update whose origin isn't itself (that's how a
   * keystroke becomes an outbound frame), so a bare `Y.applyUpdate(doc, update)`
   * would look like a local edit and get echoed back on the next connect. Going
   * through here applies under the session's own origin, which the outbound
   * filter skips. Safe to call before `resume()`: the state folds into the
   * SyncStep1 handshake instead of being re-sent.
   */
  applyRemoteUpdate(update) {
    if (this.#state.phase !== "destroyed") applyUpdate2(this.doc, update, this);
  }
  /**
   * Decode and apply one incoming binary protocol frame (document sync or
   * awareness). Returns a reply frame to transmit (e.g. SyncStep2 answering a
   * SyncStep1), or null if there's nothing to send.
   */
  receive(frame) {
    if (this.#state.phase === "destroyed") return null;
    const { cycle } = this.#state;
    try {
      if (!validateFrame(frame)) return null;
      const decoder = createDecoder(frame);
      const encoder = createEncoder();
      const type = readVarUint(decoder);
      switch (type) {
        case MessageType.Sync: {
          writeVarUint(encoder, MessageType.Sync);
          const report = (error) => {
            if (this.#current(cycle)) this.#onError(error, "receive");
          };
          const syncType = readSyncMessage(decoder, encoder, this.doc, this, report);
          if (syncType === messageYjsSyncStep2 && this.#current(cycle)) {
            this.#state = { phase: "synced", cycle };
          }
          break;
        }
        case MessageType.Awareness:
          if (this.awareness) applyAwarenessUpdate(this.awareness, readVarUint8Array(decoder), this);
          break;
        default:
          return null;
      }
      return this.#current(cycle) && length(encoder) > 1 ? toUint8Array(encoder) : null;
    } catch (error) {
      if (this.#current(cycle)) this.#onError(error, "receive");
      return null;
    }
  }
  /** Detach doc/awareness listeners and stop retransmits. */
  destroy() {
    if (this.#state.phase === "destroyed") return;
    this.#state = { phase: "destroyed" };
    this.doc.off("update", this.#onDocUpdate);
    if (this.awareness && this.#onAwarenessUpdate) this.awareness.off("update", this.#onAwarenessUpdate);
    this.#delivery.destroy();
  }
  #current(cycle) {
    return this.#state.phase !== "destroyed" && this.#state.cycle === cycle;
  }
  #frameSyncStep1() {
    const e = createEncoder();
    writeVarUint(e, MessageType.Sync);
    writeSyncStep1(e, this.doc);
    return toUint8Array(e);
  }
  #frameUpdate(update) {
    const e = createEncoder();
    writeVarUint(e, MessageType.Sync);
    writeUpdate(e, update);
    return toUint8Array(e);
  }
  #frameAwareness(clients) {
    const e = createEncoder();
    writeVarUint(e, MessageType.Awareness);
    writeVarUint8Array(e, encodeAwarenessUpdate(this.awareness, clients));
    return toUint8Array(e);
  }
};
function validateFrame(frame) {
  const decoder = createDecoder(frame);
  const type = readVarUint(decoder);
  if (type === MessageType.Sync) {
    readVarUint(decoder);
    readVarUint8Array(decoder);
  } else if (type === MessageType.Awareness) {
    validateAwareness(readVarUint8Array(decoder));
  } else {
    return false;
  }
  if (hasContent(decoder)) throw new Error("frame has trailing bytes after a complete message");
  return true;
}
function validateAwareness(payload) {
  const decoder = createDecoder(payload);
  const count = readVarUint(decoder);
  for (let i = 0; i < count; i++) {
    readVarUint(decoder);
    readVarUint(decoder);
    JSON.parse(readVarString(decoder));
  }
  if (hasContent(decoder)) throw new Error("awareness payload has trailing bytes");
}

// src/base64.ts
var toBase64 = (bytes) => btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
var fromBase64 = (str) => Uint8Array.from(atob(str), (c) => c.charCodeAt(0));

// src/actioncable_provider.ts
var ActionCableProvider = class {
  doc;
  consumer;
  channelName;
  channelParams;
  awareness;
  session;
  #state = { phase: "disconnected" };
  #onError;
  // The last event sent to listeners. A refresh notifies them only when a field differs.
  #last = { status: "disconnected", pending: false };
  #statusListeners = /* @__PURE__ */ new Set();
  #resolveSynced;
  #onDocUpdate = () => this.#refreshStatus();
  // a local edit may have made the queue non-empty
  #page = null;
  /**
   * Resolves once the document has first caught up with the server. Most
   * editor bindings seed an empty document when they mount, so binding
   * before the server's state arrives makes each client insert its own
   * top-level node. Create the editor after this resolves:
   *
   *   provider.connect();
   *   await provider.whenSynced;
   *   // now hand the doc to the editor binding
   *
   * It resolves on the first catch-up and remains resolved across later
   * reconnects, even while `synced` is false during a re-handshake. Use
   * `onStatusChange` to track the live connection. If the provider is
   * destroyed before the first sync, it never resolves.
   */
  whenSynced = new Promise((resolve) => {
    this.#resolveSynced = resolve;
  });
  constructor(doc, consumer, channelName, channelParams = {}, opts = {}) {
    this.doc = doc;
    this.consumer = consumer;
    this.channelName = channelName;
    this.channelParams = channelParams;
    const onError = opts.onError ?? ((error, context) => console.warn(`[yrby] ${context}:`, error));
    this.#onError = (error, context) => {
      try {
        onError(error, context);
      } catch (callbackError) {
        console.warn("[yrby] onError callback failed:", callbackError, "while reporting:", error);
      }
    };
    this.awareness = new ProviderAwareness(doc, this.#onError);
    this.session = new YProtocolSession(doc, {
      awareness: this.awareness,
      resendInterval: opts.resendInterval,
      onError: this.#onError,
      send: (frame, id) => this.#send(frame, id)
    });
    this.doc.on("update", this.#onDocUpdate);
  }
  /** True once the document has caught up with the server (received a SyncStep2). */
  get synced() {
    return this.session.synced;
  }
  /** True while there are unacknowledged local document updates in flight. */
  get hasPending() {
    return this.session.hasPending;
  }
  /**
   * Apply a bootstrap/restore update (initial HTTP state, a server snapshot, an
   * import) without re-sending it to the server as a local edit. Call it once per
   * chunk of already-durable state when seeding the doc, before `connect()`:
   *
   *   provider.applyRemoteUpdate(fromBase64(initialState));
   *   priorUpdates.forEach((u) => provider.applyRemoteUpdate(fromBase64(u)));
   *   provider.connect();
   *
   * See {@link YProtocolSession.applyRemoteUpdate} for why a bare `Y.applyUpdate`
   * would be re-broadcast as a pending change instead.
   */
  applyRemoteUpdate(update) {
    this.session.applyRemoteUpdate(update);
  }
  /** Current connection status. See {@link ProviderStatus}. */
  get status() {
    return this.#computeStatus();
  }
  /** Subscribe to status changes. Returns an unsubscribe function. */
  onStatusChange(listener) {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }
  connect() {
    if (this.#destroying()) throw new Error("provider is destroyed");
    if (this.#state.phase !== "disconnected") return;
    const attempt = {};
    this.#state = { phase: "subscribing", attempt };
    const on = (callback) => (...args) => {
      const run = () => {
        if (this.#active(attempt)) callback(...args);
      };
      if (this.#state.phase === "subscribing") queueMicrotask(run);
      else run();
    };
    let subscription;
    try {
      subscription = this.consumer.subscriptions.create(
        { channel: this.channelName, ...this.channelParams },
        {
          received: on((message) => this.#receive(message, attempt)),
          connected: on(() => this.#connected()),
          disconnected: on(() => this.#lost()),
          rejected: on(() => this.#stop("reject"))
        }
      );
    } catch (error) {
      if (!this.#subscribing(attempt)) return;
      this.#state = { phase: "disconnected" };
      this.#refreshStatus();
      throw error;
    }
    if (!this.#subscribing(attempt)) {
      this.#unsubscribe(subscription);
      return;
    }
    this.#state = { phase: "connecting", attempt, subscription };
    this.#watchPage();
    this.#refreshStatus();
  }
  disconnect() {
    this.#stop("disconnect");
  }
  /**
   * Resubscribes with updated channel params, such as a renewed grant. This
   * replaces only the cable subscription and keeps the doc, the delivery
   * queue, awareness, and this provider's ack route. Does nothing after
   * destroy().
   */
  renew(params) {
    if (this.#destroying()) return;
    Object.assign(this.channelParams, params);
    this.disconnect();
    this.connect();
  }
  destroy() {
    this.#stop("destroy");
  }
  #destroying() {
    const state = this.#state;
    return state.phase === "destroyed" || state.phase === "stopping" && state.reason === "destroy";
  }
  #subscribing(attempt) {
    return this.#state.phase === "subscribing" && this.#state.attempt === attempt;
  }
  // Cable callbacks run only for a connecting or connected subscription.
  #active(attempt) {
    const state = this.#state;
    return (state.phase === "connecting" || state.phase === "connected") && state.attempt === attempt;
  }
  // The cable callbacks below run only for the active attempt, which on() in
  // connect() checks.
  #connected() {
    const state = this.#state;
    if (state.phase !== "connecting") return;
    this.#state = { ...state, phase: "connected" };
    this.session.resume();
    this.#refreshStatus();
  }
  #lost() {
    const state = this.#state;
    if (state.phase !== "connecting" && state.phase !== "connected") return;
    this.#state = { ...state, phase: "connecting" };
    this.session.pause();
    this.#refreshStatus();
  }
  #stop(reason) {
    const state = this.#state;
    if (state.phase === "destroyed") return;
    if (state.phase === "stopping") {
      if (reason === "destroy") state.reason = reason;
      return;
    }
    if (state.phase === "disconnected" && reason === "disconnect") return;
    let finalReason = reason;
    if ("subscription" in state) {
      const stopping = { ...state, phase: "stopping", reason };
      this.#state = stopping;
      this.#unwatchPage();
      this.session.removeLocalAwareness();
      this.session.pause();
      this.#unsubscribe(state.subscription);
      if (this.#state !== stopping) return;
      finalReason = stopping.reason;
    }
    const destroyed = finalReason === "destroy";
    this.#state = { phase: destroyed ? "destroyed" : "disconnected" };
    if (destroyed) this.#destroyOwned();
    else if (finalReason === "reject") this.#onError(new Error("subscription rejected by the server"), "rejected");
    this.#refreshStatus();
    if (destroyed) this.#statusListeners.clear();
  }
  #destroyOwned() {
    this.session.destroy();
    this.awareness.destroy();
    this.doc.off("update", this.#onDocUpdate);
  }
  #unsubscribe(subscription) {
    queueMicrotask(() => {
      try {
        subscription.unsubscribe?.();
      } catch (error) {
        this.#onError(error, "unsubscribe");
      }
    });
  }
  #receive(message, attempt) {
    if (message && message.ack !== void 0) {
      this.session.acknowledge(message.ack);
      this.#refreshStatus();
      return;
    }
    const awarenessPayload = message && message.awareness;
    const payload = message && (awarenessPayload ?? message.update);
    if (typeof payload !== "string") return;
    let frame;
    try {
      frame = fromBase64(payload);
    } catch (error) {
      this.#onError(error, "received");
      return;
    }
    if (awarenessPayload !== void 0 && frame[0] !== MessageType.Awareness) {
      this.#onError(new Error("awareness envelope carried a non-awareness frame"), "received");
      return;
    }
    const reply = this.session.receive(frame);
    if (reply && this.#active(attempt)) this.#send(reply, void 0);
    this.#refreshStatus();
  }
  #computeStatus() {
    switch (this.#state.phase) {
      case "subscribing":
      case "connecting":
        return "connecting";
      case "connected":
        return this.session.synced ? "synced" : "connected";
      default:
        return "disconnected";
    }
  }
  #refreshStatus() {
    const status = this.#computeStatus();
    const pending = this.hasPending;
    if (status === this.#last.status && pending === this.#last.pending) return;
    const event = this.#last = { status, pending };
    if (status === "synced") this.#resolveSynced();
    for (const listener of this.#statusListeners) {
      if (this.#last !== event) break;
      try {
        listener({ status, pending });
      } catch (error) {
        this.#onError(error, "listener");
      }
    }
  }
  // Handles presence across the page lifecycle. `pagehide` removes our cursor
  // while the socket is still live, so peers drop it without waiting for the
  // awareness timeout. A `pageshow` with `persisted` means the user came back
  // through the bfcache, so we restore the cursor. Editor bindings set
  // awareness only once at setup, so without this the user would return with
  // no cursor.
  #watchPage() {
    if (typeof window === "undefined" || this.#page) return;
    let stashed = null;
    const page = this.#page = {
      hide: () => {
        if (this.#page !== page) return;
        stashed = this.awareness.getLocalState();
        this.session.removeLocalAwareness();
      },
      show: (event) => {
        if (this.#page !== page || !event.persisted || !stashed) return;
        if (this.awareness.getLocalState() === null) this.awareness.setLocalState(stashed);
        stashed = null;
      }
    };
    window.addEventListener("pagehide", this.#page.hide);
    window.addEventListener("pageshow", this.#page.show);
  }
  #unwatchPage() {
    if (!this.#page || typeof window === "undefined") return;
    const page = this.#page;
    this.#page = null;
    window.removeEventListener("pagehide", page.hide);
    window.removeEventListener("pageshow", page.show);
  }
  // Send one raw protocol frame over the cable. Awareness frames are whispered
  // when AnyCable exposes `subscription.whisper`; otherwise they fall back to a
  // normal send. `id` (reliable doc updates) is tagged onto the envelope so the
  // server can ack. A no-op while disconnected: reliable frames stay queued in
  // the session and flush on the next connect().
  #send(frame, id) {
    const state = this.#state;
    if (!("subscription" in state)) return;
    const isAwareness = frame[0] === MessageType.Awareness;
    if (state.phase === "stopping" && !isAwareness) return;
    const { subscription } = state;
    const update = toBase64(frame);
    const report = (error) => {
      const current = this.#state;
      if ("subscription" in current && current.subscription === subscription) this.#onError(error, "send");
    };
    try {
      const result = isAwareness && typeof subscription.whisper === "function" ? subscription.whisper({ awareness: update }) : subscription.send(id === void 0 ? { update } : { update, id });
      if (result instanceof Promise) result.catch(report);
    } catch (error) {
      report(error);
    }
  }
};
var ProviderAwareness = class extends Awareness {
  constructor(doc, onError) {
    super(doc);
    this.onError = onError;
  }
  emit(...args) {
    try {
      super.emit(...args);
    } catch (error) {
      this.onError(error, `awareness:${args[0]}`);
    }
  }
};

// src/document_session.ts
import * as Y3 from "yjs";

// node_modules/lib0/webcrypto.js
var subtle = crypto.subtle;
var getRandomValues = crypto.getRandomValues.bind(crypto);

// node_modules/lib0/random.js
var uint32 = () => getRandomValues(new Uint32Array(1))[0];
var uuidv4Template = "10000000-1000-4000-8000" + -1e11;
var uuidv4 = () => uuidv4Template.replace(
  /[018]/g,
  /** @param {number} c */
  (c) => (c ^ uint32() & 15 >> c / 4).toString(16)
);

// src/document_session.ts
var PHASES = {
  open: { state: "open", connects: true, on: { refresh: "refreshing", block: "blocked", close: "closed" } },
  refreshing: { state: "open", connects: false, on: { renew: "renewed", block: "blocked", close: "closed" } },
  renewed: { state: "open", connects: true, on: { accept: "open", block: "blocked", close: "closed" } },
  blocked: { state: "blocked", connects: false, on: { retry: "open", close: "closed" } },
  closed: { state: "closed", connects: false, on: {} }
};
var REFRESH_TIMEOUT_MS = 15e3;
var DEFAULT_CHANNEL = "Y::DocumentChannel";
var stores = /* @__PURE__ */ new WeakMap();
function documentKey(descriptor) {
  return JSON.stringify([descriptor.channel || DEFAULT_CHANNEL, descriptor.grant, descriptor.name]);
}
var storeToken = Symbol("storeToken");
var attachLease = Symbol("attachLease");
var notifyStoreChange = Symbol("notifyStoreChange");
var DocumentSessionStore = class _DocumentSessionStore extends EventTarget {
  constructor(consumer, token) {
    super();
    this.consumer = consumer;
    if (token !== storeToken) throw new Error("Use DocumentSessionStore.for(consumer)");
  }
  static for(consumer) {
    let store = stores.get(consumer);
    if (!store) stores.set(consumer, store = new _DocumentSessionStore(consumer, storeToken));
    return store;
  }
  #sessions = /* @__PURE__ */ new Map();
  get sessions() {
    return [...this.#sessions.values()];
  }
  /** Acquire a lease on this document session, creating it on first use. */
  acquire(input) {
    if (!input.grant || !input.name) throw new Error("A document requires a grant and name");
    const descriptor = Object.freeze({
      channel: input.channel || DEFAULT_CHANNEL,
      grant: input.grant,
      name: input.name,
      ...input.refresh ? { refresh: input.refresh } : {}
    });
    const key = documentKey(descriptor);
    let session = this.#sessions.get(key);
    if (!session) {
      session = new DocumentSession(this, descriptor, () => {
        this.#sessions.delete(key);
      });
      this.#sessions.set(key, session);
    }
    return session[attachLease]();
  }
  [notifyStoreChange](session) {
    this.dispatchEvent(new CustomEvent("change", { detail: session }));
  }
};
var DocumentLease = class {
  constructor(session, onRelease) {
    this.session = session;
    this.#onRelease = onRelease;
  }
  #controller = new AbortController();
  #onRelease;
  /** Aborts when the lease ends, including when the session blocks or is discarded. */
  get signal() {
    return this.#controller.signal;
  }
  setPresence(state) {
    if (!this.signal.aborted) this.session.provider.awareness.setLocalState(state);
  }
  /** Runs editor cleanup synchronously, before the final check for pending work. */
  release() {
    if (this.signal.aborted) return;
    this.#controller.abort();
    this.#onRelease();
  }
};
var DocumentSession = class {
  /** Create and hold sessions through DocumentSessionStore.acquire. */
  constructor(store, descriptor, remove) {
    this.store = store;
    this.descriptor = descriptor;
    this.remove = remove;
    this.provider = new ActionCableProvider(this.doc, store.consumer, descriptor.channel, {
      grant: descriptor.grant,
      name: descriptor.name,
      // Ack sequence numbers are per session, not per record.
      session_id: uuidv4()
    }, {
      onError: (error, context) => {
        if (context === "rejected") this.#rejected(error);
        else if (this.state !== "closed") {
          this.#error = error;
          this.#changed();
        }
      }
    });
    this.provider.awareness.setLocalState(null);
    this.provider.onStatusChange(({ status }) => {
      if (this.state !== "open") return;
      if (status === "connected" || status === "synced") this.#transition("accept");
      this.#changed();
    });
  }
  doc = new Y3.Doc();
  provider;
  #lifecycle = { phase: "open" };
  #leases = /* @__PURE__ */ new Set();
  // Leases held when the session blocked. Settle releases these and keeps any
  // lease acquired while blocked for retry().
  #retiring;
  #error;
  #dirty = false;
  // true until store observers are notified of the latest change
  #settleQueued = false;
  get error() {
    return this.#error;
  }
  get hasPending() {
    return this.provider.hasPending;
  }
  get whenSynced() {
    return this.provider.whenSynced;
  }
  get state() {
    return PHASES[this.#lifecycle.phase].state;
  }
  [attachLease]() {
    if (this.state === "closed") throw new Error("Cannot acquire a closed document session");
    const lease = new DocumentLease(this, () => this.#release(lease));
    this.#leases.add(lease);
    this.#changed();
    if (PHASES[this.#lifecycle.phase].connects) this.#connect();
    return lease;
  }
  #release(lease) {
    if (!this.#leases.delete(lease)) return;
    this.#changed();
    if (!this.#leases.size) this.provider.awareness.setLocalState(null);
  }
  /** Reconnects with this session's current grant, which is the original one or the last one a refresh returned. */
  retry() {
    if (this.#transition("retry")) this.#connect();
  }
  /** Closes the session and drops pending work. The application calls this explicitly, because an ordinary detach keeps pending work. */
  discard() {
    this.#close();
  }
  #changed() {
    this.#dirty = true;
    if (this.#settleQueued) return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle() {
    this.#settleQueued = false;
    this.#enforce();
    if (!this.#dirty) return;
    this.#dirty = false;
    this.store[notifyStoreChange](this);
  }
  #enforce() {
    if (this.state === "closed") return;
    if (this.state === "blocked") {
      const retiring = this.#retiring;
      this.#retiring = void 0;
      for (const lease of retiring ?? []) lease.release();
      return;
    }
    if (!this.#needed()) this.#close();
  }
  // Connect with the current grant, or resubscribe with a renewed one. The
  // provider defers its own callbacks, so a failure here only blocks.
  #connect(grant) {
    try {
      if (grant === void 0) this.provider.connect();
      else this.provider.renew({ grant });
    } catch (error) {
      this.#transition("block", error);
    }
  }
  #needed() {
    return this.#leases.size > 0 || this.provider.hasPending;
  }
  // The only method that changes the phase. It doesn't call out to other code,
  // and #settle acts on the result.
  #transition(event, error) {
    const phase = PHASES[this.#lifecycle.phase].on[event];
    if (!phase) return false;
    this.#lifecycle = { phase };
    this.#retiring = phase === "blocked" ? [...this.#leases] : void 0;
    if (event === "retry") this.#error = void 0;
    else if (event === "block") this.#error = error;
    this.#changed();
    return true;
  }
  #close() {
    if (!this.#transition("close")) return;
    this.remove();
    for (const lease of [...this.#leases]) lease.release();
    this.provider.destroy();
    this.doc.destroy();
  }
  // Try the refresh URL once per rejection. Block if the server rejects again
  // while refreshing or rejects the renewed grant.
  #rejected(error) {
    const url = this.descriptor.refresh;
    if (url && this.#transition("refresh")) void this.#refresh(url, this.#lifecycle);
    else this.#transition("block", error);
  }
  async #refresh(url, attempt) {
    let grant;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      if (this.#lifecycle === attempt) this.#transition("block", error);
      return;
    }
    if (this.#lifecycle !== attempt) return;
    if (this.#transition("renew")) this.#connect(grant);
  }
};
async function fetchGrant(url) {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS)
  });
  if (!response.ok) throw new Error(`grant refresh failed: ${response.status}`);
  const body = await response.json();
  const grant = body?.grant;
  if (typeof grant !== "string" || !grant) throw new Error("grant refresh returned no grant");
  return grant;
}

// src/turbo_adapter.ts
var adapters = /* @__PURE__ */ new WeakMap();
var CACHE_EVENTS = ["turbo:before-cache", "turbolinks:before-cache"];
var RENDER_EVENTS = ["turbo:render", "turbo:load", "turbo:fetch-request-error", "turbolinks:render", "turbolinks:load"];
var PREVIEW_ATTRIBUTES = ["data-turbo-preview", "data-turbolinks-preview"];
function registerDocumentMount(mount) {
  let adapter = adapters.get(mount.ownerDocument);
  if (!adapter) adapters.set(mount.ownerDocument, adapter = new TurboAdapter(mount.ownerDocument));
  adapter.mounts.add(mount);
  adapter.reconcile();
  return () => {
    adapter.mounts.delete(mount);
    if (!adapter.mounts.size) adapter.destroy();
  };
}
var TurboAdapter = class {
  constructor(document) {
    this.document = document;
    for (const event of CACHE_EVENTS) document.addEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS) document.addEventListener(event, this.reconcile);
  }
  mounts = /* @__PURE__ */ new Set();
  #state = { phase: "active" };
  reconcile = () => {
    if (this.#state.phase !== "active") return;
    const html = this.document.documentElement;
    const preview = PREVIEW_ATTRIBUTES.some((attribute) => html?.hasAttribute(attribute));
    for (const mount of this.mounts) {
      if (!mount.isConnected || preview) mount.deactivate();
      else mount.activate();
    }
  };
  #beforeCache = () => {
    const state = this.#state;
    if (state.phase !== "active") return;
    for (const mount of this.mounts) mount.deactivate();
    if (this.#state !== state) return;
    clearTimeout(state.timer);
    state.timer = setTimeout(() => {
      if (this.#state === state) state.timer = setTimeout(this.reconcile, 0);
    }, 0);
  };
  destroy() {
    const state = this.#state;
    if (state.phase === "destroyed") return;
    this.#state = { phase: "destroyed" };
    clearTimeout(state.timer);
    adapters.delete(this.document);
    for (const event of CACHE_EVENTS) this.document.removeEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS) this.document.removeEventListener(event, this.reconcile);
    for (const mount of this.mounts) mount.deactivate();
    this.mounts.clear();
  }
};

// src/document_element.ts
var Base = typeof HTMLElement === "undefined" ? class {
} : HTMLElement;
var INERT_ATTRIBUTE = "data-yrby-inert";
var sharedConsumer;
function defaultConsumer() {
  sharedConsumer ??= import("@rails/actioncable").then((actioncable) => actioncable.createConsumer()).catch((error) => {
    sharedConsumer = void 0;
    throw error;
  });
  return sharedConsumer;
}
var assignedConsumer;
var factoryResult;
function loadConsumer(source) {
  if (source == null) return defaultConsumer();
  if (typeof source !== "function") return Promise.resolve(source);
  if (factoryResult?.factory === source) return factoryResult.consumer;
  let consumer;
  try {
    consumer = Promise.resolve(source());
  } catch (error) {
    return Promise.reject(error);
  }
  const entry = { factory: source, consumer };
  factoryResult = entry;
  consumer.catch(() => {
    if (factoryResult === entry) factoryResult = void 0;
  });
  return consumer;
}
function deferred() {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
function blockReport(session) {
  return session.state === "blocked" ? { error: session.error, session } : void 0;
}
var YrbyDocumentElement = class _YrbyDocumentElement extends Base {
  /**
   * Set before adding elements to use another consumer, such as AnyCable's.
   * It takes a consumer, a promise of one, or a function that returns either.
   * The element calls the function when it first needs a consumer and reuses
   * the result. If the function throws or its promise rejects, the next
   * attempt calls it again. Assigning a different value replaces the reused
   * result. When unset, elements share an `@rails/actioncable` consumer.
   */
  static get consumer() {
    return assignedConsumer;
  }
  static set consumer(value) {
    if (value === assignedConsumer) return;
    assignedConsumer = value;
    factoryResult = void 0;
  }
  // refresh is read when the session is acquired and isn't part of the
  // document's identity, so changing it doesn't rebind the editor.
  static observedAttributes = ["grant", "name", "channel"];
  #live = false;
  // false while Turbo is showing a cached copy of the page
  #attempt;
  // Key of the document whose session blocked or failed. The element won't retry
  // it until the page renders again, the attributes change, or the element is
  // re-inserted.
  #stalledKey;
  #unregister;
  #settleQueued = false;
  // Resolves when the current attempt first syncs. Abandoning the attempt replaces it.
  #firstSync = deferred();
  get session() {
    const lease = this.#attempt?.lease;
    return lease && !lease.signal.aborted ? lease.session : void 0;
  }
  get doc() {
    return this.session?.doc;
  }
  get provider() {
    return this.session?.provider;
  }
  /** Resolves after the current attempt's first sync. If the attempt is abandoned, its promise never resolves. */
  get whenSynced() {
    return this.#firstSync.promise;
  }
  /**
   * The `yrby:synced` detail of the session the element is bound to. It is
   * undefined before the first sync, while the element retargets or the page
   * is cached, while the document is stalled, and as soon as the lease aborts.
   * Reading it never creates anything.
   */
  get current() {
    const detail = this.#attempt?.announced;
    return detail && !detail.signal.aborted ? detail : void 0;
  }
  connectedCallback() {
    this.#stalledKey = void 0;
    if (!this.#attempt) this.#holdInert();
    this.#unregister ??= registerDocumentMount(this);
    this.#requestSettle();
  }
  // Same-turn moves keep their binding, because settle checks isConnected afterwards.
  disconnectedCallback() {
    this.#requestSettle();
  }
  attributeChangedCallback(_name, oldValue, newValue) {
    if (oldValue === newValue) return;
    this.#stalledKey = void 0;
    this.#abandon();
    this.#requestSettle();
  }
  /** @internal Called by the Turbo adapter when the page is live. A new render also retries a stalled document. */
  activate() {
    this.#live = true;
    this.#stalledKey = void 0;
    this.#requestSettle();
  }
  /** @internal Called by the Turbo adapter when the page is cached or previewed. */
  deactivate() {
    this.#live = false;
    this.#abandon();
  }
  /**
   * Acquires the document again after its session blocked or was discarded.
   * It doesn't change whether the page is live, so a cached page binds when
   * Turbo shows it again. It does nothing while the element is bound to, or
   * still acquiring, a session whose lease hasn't aborted.
   *
   * It is safe to call from a lease abort handler, or right after
   * `session.discard()` in the same call stack. The element drops the ended
   * attempt immediately, so the settle that would have stalled it acquires
   * instead. A discarded session is gone from the store, so that acquisition
   * creates a new session with a new `Y.Doc`. A session that is still blocked
   * is reported again with `yrby:error`.
   */
  retry() {
    const attempt = this.#attempt;
    if (attempt && !attempt.ended && !attempt.lease?.signal.aborted) return;
    this.#stalledKey = void 0;
    this.#abandon();
    this.#requestSettle();
  }
  /** Releases the editor lease. The session keeps any unsaved work. */
  destroy() {
    this.#live = false;
    const unregister = this.#unregister;
    this.#unregister = void 0;
    unregister?.();
    this.#abandon();
  }
  #requestSettle() {
    if (this.#settleQueued) return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle() {
    this.#settleQueued = false;
    if (!this.isConnected) {
      this.destroy();
      return;
    }
    const descriptor = this.#descriptor();
    const key = this.#live && descriptor.grant && descriptor.name ? documentKey(descriptor) : void 0;
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      this.#abandon();
      this.#requestSettle();
      return;
    }
    if (key === void 0 || key === this.#stalledKey) return;
    if (!attempt) this.#start(key, descriptor);
    else if (attempt.ended) this.#stall(attempt.ended.detail);
    else if (attempt.consumer && !attempt.lease) this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced) this.#announce(attempt);
  }
  #start(key, descriptor) {
    const attempt = { key, descriptor };
    this.#attempt = attempt;
    loadConsumer(_YrbyDocumentElement.consumer).then(
      (consumer) => {
        attempt.consumer = consumer;
      },
      (error) => {
        attempt.ended = { detail: { error } };
      }
    ).then(() => this.#requestSettle());
  }
  #acquire(attempt, consumer) {
    let lease;
    try {
      lease = DocumentSessionStore.for(consumer).acquire(attempt.descriptor);
    } catch (error) {
      this.#stall({ error });
      return;
    }
    attempt.lease = lease;
    const { session } = lease;
    const blocked = blockReport(session);
    if (blocked) {
      attempt.ended = { detail: blocked };
      this.#requestSettle();
      return;
    }
    lease.signal.addEventListener("abort", () => {
      attempt.ended ??= { detail: blockReport(session) };
      this.#requestSettle();
    }, { once: true });
    void session.whenSynced.then(() => {
      attempt.synced = true;
      this.#requestSettle();
    });
  }
  #announce(attempt) {
    const lease = attempt.lease;
    const { session } = lease;
    const detail = { session, doc: session.doc, provider: session.provider, lease, signal: lease.signal };
    attempt.announced = detail;
    this.#restoreInert();
    this.#firstSync.resolve();
    this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true, detail }));
  }
  #stall(detail) {
    this.#stalledKey = this.#attempt?.key;
    this.#abandon();
    if (detail) this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail }));
  }
  // Ends the current attempt. Releasing the lease runs editor cleanup, which
  // may change attributes or move the element, and those changes only request
  // a settle.
  #abandon() {
    const attempt = this.#attempt;
    if (!attempt) return;
    this.#attempt = void 0;
    this.#firstSync = deferred();
    this.#holdInert();
    attempt.lease?.release();
  }
  #descriptor() {
    return {
      channel: this.getAttribute("channel") || void 0,
      grant: this.getAttribute("grant") || "",
      name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || void 0
    };
  }
  // Stay inert until synced so nobody types into a document that isn't live yet.
  // The application's own inert value goes in an attribute, which survives a
  // Turbo cache clone, and is restored when the element is ready.
  #holdInert() {
    if (!this.hasAttribute(INERT_ATTRIBUTE)) this.setAttribute(INERT_ATTRIBUTE, String(this.inert));
    this.inert = true;
  }
  #restoreInert() {
    const saved = this.getAttribute(INERT_ATTRIBUTE);
    if (saved === null) return;
    this.inert = saved === "true";
    this.removeAttribute(INERT_ATTRIBUTE);
  }
};
if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
export {
  ActionCableProvider,
  DocumentSessionStore,
  MessageType,
  ReliableSync,
  YProtocolSession,
  YrbyDocumentElement,
  fromBase64,
  toBase64
};
//# sourceMappingURL=yrby-client.js.map
