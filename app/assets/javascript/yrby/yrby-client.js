// src/reliable_sync.ts
var DEFAULT_RESEND_INTERVAL = 1000;

class ReliableSync {
  #pending = [];
  #send;
  #merge;
  #resendInterval;
  #setInterval;
  #clearInterval;
  #nextSeq = 1;
  #phase = "paused";
  #timer;
  #version = 0;
  #tail;
  constructor(opts) {
    const { send, merge, resendInterval, setInterval: setTimer, clearInterval: clearTimer } = opts ?? {};
    if (typeof send !== "function")
      throw new TypeError("ReliableSync requires a send(update, id) function");
    if (typeof merge !== "function")
      throw new TypeError("ReliableSync requires a merge(updates) function");
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
  get pending() {
    return this.#pending.map(({ seq, update }) => ({ seq, update: update.slice() }));
  }
  get hasPending() {
    return this.#pending.length > 0;
  }
  enqueue(update) {
    if (this.#phase === "destroyed")
      return;
    this.#pending.push({ seq: this.#nextSeq++, update: new Uint8Array(update) });
    this.#queueChanged();
    this.#flush();
  }
  acknowledge(id) {
    if (this.#phase === "destroyed" || !Number.isSafeInteger(id) || id < 0)
      return;
    const newest = this.#pending.at(-1);
    if (newest && id > newest.seq)
      return;
    this.#pending = this.#pending.filter((p) => p.seq > id);
    this.#queueChanged();
  }
  resume() {
    if (this.#phase === "destroyed")
      return;
    this.#phase = "live";
    this.#version++;
    this.#updateTimer();
    this.#flush();
  }
  pause() {
    if (this.#phase === "destroyed")
      return;
    this.#phase = "paused";
    this.#version++;
    this.#updateTimer();
  }
  retransmit() {
    this.#flush();
  }
  destroy() {
    if (this.#phase === "destroyed")
      return;
    this.#phase = "destroyed";
    this.#pending = [];
    this.#queueChanged();
  }
  #queueChanged() {
    this.#version++;
    this.#tail = undefined;
    this.#updateTimer();
  }
  #updateTimer() {
    const wanted = this.#phase === "live" && this.hasPending;
    if (wanted === (this.#timer !== undefined))
      return;
    if (!wanted) {
      const timer = this.#timer;
      this.#timer = undefined;
      timer.stop();
      return;
    }
    const timer = this.#timer = { stop: () => {} };
    let handle;
    try {
      handle = this.#setInterval(() => {
        if (this.#timer === timer)
          this.#flush();
      }, this.#resendInterval);
    } catch (error) {
      if (this.#timer === timer)
        this.#timer = undefined;
      throw error;
    }
    timer.stop = () => this.#clearInterval(handle);
    if (this.#timer !== timer) {
      timer.stop();
      return;
    }
    handle?.unref?.();
  }
  #flush() {
    if (this.#phase !== "live" || !this.#pending.length)
      return;
    if (this.#tail === undefined) {
      const version = this.#version;
      const updates = this.#pending.map((p) => p.update);
      const tail = updates.length === 1 ? updates[0] : this.#merge(updates);
      if (this.#version !== version)
        return;
      this.#tail = tail;
    }
    this.#send(this.#tail, this.#pending.at(-1).seq);
  }
}
// src/y_protocol_session.ts
import { mergeUpdates, applyUpdate as applyUpdate2 } from "yjs";

// node_modules/lib0/math.js
var floor = Math.floor;
var min = (a, b) => a < b ? a : b;
var max = (a, b) => a > b ? a : b;

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

// node_modules/lib0/set.js
var create = () => new Set;

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
  for (let i = 0;i < len; i++) {
    buf[i] = encodedString.codePointAt(i);
  }
  return buf;
};
var utf8TextEncoder = typeof TextEncoder !== "undefined" ? new TextEncoder : null;
var _encodeUtf8Native = (str) => utf8TextEncoder.encode(str);
var encodeUtf8 = utf8TextEncoder ? _encodeUtf8Native : _encodeUtf8Polyfill;
var utf8TextDecoder = typeof TextDecoder === "undefined" ? null : new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
if (utf8TextDecoder && utf8TextDecoder.decode(new Uint8Array).length === 1) {
  utf8TextDecoder = null;
}

// node_modules/lib0/encoding.js
class Encoder {
  constructor() {
    this.cpos = 0;
    this.cbuf = new Uint8Array(100);
    this.bufs = [];
  }
}
var createEncoder = () => new Encoder;
var length = (encoder) => {
  let len = encoder.cpos;
  for (let i = 0;i < encoder.bufs.length; i++) {
    len += encoder.bufs[i].length;
  }
  return len;
};
var toUint8Array = (encoder) => {
  const uint8arr = new Uint8Array(length(encoder));
  let curPos = 0;
  for (let i = 0;i < encoder.bufs.length; i++) {
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
var _strBuffer = new Uint8Array(30000);
var _maxStrBSize = _strBuffer.length / 3;
var _writeVarStringNative = (encoder, str) => {
  if (str.length < _maxStrBSize) {
    const written = utf8TextEncoder.encodeInto(str, _strBuffer).written || 0;
    writeVarUint(encoder, written);
    for (let i = 0;i < written; i++) {
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
  for (let i = 0;i < len; i++) {
    write(encoder, encodedString.codePointAt(i));
  }
};
var writeVarString = utf8TextEncoder && utf8TextEncoder.encodeInto ? _writeVarStringNative : _writeVarStringPolyfill;
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

class Decoder {
  constructor(uint8Array) {
    this.arr = uint8Array;
    this.pos = 0;
  }
}
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
        encodedString += String.fromCodePoint.apply(null, bytes);
        remainingLen -= nextLen;
      }
    }
    return decodeURIComponent(escape(encodedString));
  }
};
var _readVarStringNative = (decoder) => utf8TextDecoder.decode(readVarUint8Array(decoder));
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
    if (errorHandler != null)
      errorHandler(error);
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
var create3 = () => new Map;
var setIfUndefined = (map, key, createT) => {
  let set = map.get(key);
  if (set === undefined) {
    map.set(key, set = createT());
  }
  return set;
};

// node_modules/lib0/observable.js
class Observable {
  constructor() {
    this._observers = create3();
  }
  on(name, f) {
    setIfUndefined(this._observers, name, create).add(f);
  }
  once(name, f) {
    const _f = (...args) => {
      this.off(name, _f);
      f(...args);
    };
    this.on(name, _f);
  }
  off(name, f) {
    const observers = this._observers.get(name);
    if (observers !== undefined) {
      observers.delete(f);
      if (observers.size === 0) {
        this._observers.delete(name);
      }
    }
  }
  emit(name, args) {
    return from((this._observers.get(name) || create3()).values()).forEach((f) => f(...args));
  }
  destroy() {
    this._observers = create3();
  }
}

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
    case Uint8Array: {
      if (a.byteLength !== b.byteLength) {
        return false;
      }
      for (let i = 0;i < a.length; i++) {
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
    case undefined:
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
      for (let i = 0;i < a.length; i++) {
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
var outdatedTimeout = 30000;

class Awareness extends Observable {
  constructor(doc) {
    super();
    this.doc = doc;
    this.clientID = doc.clientID;
    this.states = new Map;
    this.meta = new Map;
    this._checkInterval = setInterval(() => {
      const now = getUnixTime();
      if (this.getLocalState() !== null && outdatedTimeout / 2 <= now - this.meta.get(this.clientID).lastUpdated) {
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
  getLocalState() {
    return this.states.get(this.clientID) || null;
  }
  setLocalState(state) {
    const clientID = this.clientID;
    const currLocalMeta = this.meta.get(clientID);
    const clock = currLocalMeta === undefined ? 0 : currLocalMeta.clock + 1;
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
  setLocalStateField(field, value) {
    const state = this.getLocalState();
    if (state !== null) {
      this.setLocalState({
        ...state,
        [field]: value
      });
    }
  }
  getStates() {
    return this.states;
  }
}
var removeAwarenessStates = (awareness, clients, origin) => {
  const removed = [];
  for (let i = 0;i < clients.length; i++) {
    const clientID = clients[i];
    if (awareness.states.has(clientID)) {
      awareness.states.delete(clientID);
      if (clientID === awareness.clientID) {
        const curMeta = awareness.meta.get(clientID);
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
  for (let i = 0;i < len; i++) {
    const clientID = clients[i];
    const state = states.get(clientID) || null;
    const clock = awareness.meta.get(clientID).clock;
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
  for (let i = 0;i < len; i++) {
    const clientID = readVarUint(decoder);
    let clock = readVarUint(decoder);
    const state = JSON.parse(readVarString(decoder));
    const clientMeta = awareness.meta.get(clientID);
    const prevState = awareness.states.get(clientID);
    const currClock = clientMeta === undefined ? 0 : clientMeta.clock;
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
      if (clientMeta === undefined && state !== null) {
        added.push(clientID);
      } else if (clientMeta !== undefined && state === null) {
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

class YProtocolSession {
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
    if (!doc)
      throw new TypeError("YProtocolSession requires a Y.Doc");
    if (typeof send !== "function")
      throw new TypeError("YProtocolSession requires a send(frame, id) function");
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
      if (origin === this)
        return;
      this.#delivery.enqueue(update);
    };
    this.doc.on("update", this.#onDocUpdate);
    if (this.awareness) {
      this.#onAwarenessUpdate = ({ added, updated, removed }, origin) => {
        if (origin === this || this.#state.phase === "destroyed")
          return;
        const changed = added.concat(updated, removed);
        this.#send(this.#frameAwareness(changed), undefined);
      };
      this.awareness.on("update", this.#onAwarenessUpdate);
    }
  }
  get synced() {
    return this.#state.phase === "synced";
  }
  get hasPending() {
    return this.#delivery.hasPending;
  }
  resume() {
    if (this.#state.phase === "destroyed")
      return;
    const cycle = {};
    this.#state = { phase: "unsynced", cycle };
    this.#send(this.#frameSyncStep1(), undefined);
    if (!this.#current(cycle))
      return;
    if (this.awareness && this.awareness.getLocalState() !== null) {
      this.#send(this.#frameAwareness([this.doc.clientID]), undefined);
    }
    if (this.#current(cycle))
      this.#delivery.resume();
  }
  pause() {
    if (this.#state.phase === "destroyed")
      return;
    this.#state = { phase: "unsynced", cycle: {} };
    this.#delivery.pause();
    if (this.awareness) {
      const remote = [...this.awareness.getStates().keys()].filter((c) => c !== this.doc.clientID);
      if (remote.length)
        removeAwarenessStates(this.awareness, remote, this);
    }
  }
  removeLocalAwareness() {
    if (this.#state.phase !== "destroyed" && this.awareness && this.awareness.getLocalState() !== null) {
      this.awareness.setLocalState(null);
    }
  }
  acknowledge(id) {
    this.#delivery.acknowledge(id);
  }
  applyRemoteUpdate(update) {
    if (this.#state.phase !== "destroyed")
      applyUpdate2(this.doc, update, this);
  }
  receive(frame) {
    if (this.#state.phase === "destroyed")
      return null;
    const { cycle } = this.#state;
    try {
      if (!validateFrame(frame))
        return null;
      const decoder = createDecoder(frame);
      const encoder = createEncoder();
      const type = readVarUint(decoder);
      switch (type) {
        case MessageType.Sync: {
          writeVarUint(encoder, MessageType.Sync);
          const report = (error) => {
            if (this.#current(cycle))
              this.#onError(error, "receive");
          };
          const syncType = readSyncMessage(decoder, encoder, this.doc, this, report);
          if (syncType === messageYjsSyncStep2 && this.#current(cycle)) {
            this.#state = { phase: "synced", cycle };
          }
          break;
        }
        case MessageType.Awareness:
          if (this.awareness)
            applyAwarenessUpdate(this.awareness, readVarUint8Array(decoder), this);
          break;
        default:
          return null;
      }
      return this.#current(cycle) && length(encoder) > 1 ? toUint8Array(encoder) : null;
    } catch (error) {
      if (this.#current(cycle))
        this.#onError(error, "receive");
      return null;
    }
  }
  destroy() {
    if (this.#state.phase === "destroyed")
      return;
    this.#state = { phase: "destroyed" };
    this.doc.off("update", this.#onDocUpdate);
    if (this.awareness && this.#onAwarenessUpdate)
      this.awareness.off("update", this.#onAwarenessUpdate);
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
}
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
  if (hasContent(decoder))
    throw new Error("frame has trailing bytes after a complete message");
  return true;
}
function validateAwareness(payload) {
  const decoder = createDecoder(payload);
  const count = readVarUint(decoder);
  for (let i = 0;i < count; i++) {
    readVarUint(decoder);
    readVarUint(decoder);
    JSON.parse(readVarString(decoder));
  }
  if (hasContent(decoder))
    throw new Error("awareness payload has trailing bytes");
}
// src/base64.ts
var toBase64 = (bytes) => btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
var fromBase64 = (str) => Uint8Array.from(atob(str), (c) => c.charCodeAt(0));

// src/actioncable_provider.ts
class ActionCableProvider {
  doc;
  consumer;
  channelName;
  channelParams;
  awareness;
  session;
  #state = { phase: "disconnected" };
  #onError;
  #last = { status: "disconnected", pending: false };
  #statusListeners = new Set;
  #resolveSynced;
  #onDocUpdate = () => this.#refreshStatus();
  #page = null;
  #presence = null;
  #onAwarenessUpdate = ({ added, updated, removed }) => {
    if (this.#state.phase !== "disconnected")
      return;
    const id = this.awareness.clientID;
    if (added.includes(id) || updated.includes(id) || removed.includes(id))
      this.#presence = null;
  };
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
    this.awareness.on("update", this.#onAwarenessUpdate);
    this.session = new YProtocolSession(doc, {
      awareness: this.awareness,
      resendInterval: opts.resendInterval,
      onError: this.#onError,
      send: (frame, id) => this.#send(frame, id)
    });
    this.doc.on("update", this.#onDocUpdate);
  }
  get synced() {
    return this.session.synced;
  }
  get hasPending() {
    return this.session.hasPending;
  }
  applyRemoteUpdate(update) {
    this.session.applyRemoteUpdate(update);
  }
  get status() {
    return this.#computeStatus();
  }
  onStatusChange(listener) {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }
  connect() {
    if (this.#destroying())
      throw new Error("provider is destroyed");
    if (this.#state.phase !== "disconnected")
      return;
    const attempt = {};
    this.#state = { phase: "subscribing", attempt };
    const presence = this.#presence;
    this.#presence = null;
    if (presence)
      this.awareness.setLocalState(presence);
    if (!this.#subscribing(attempt))
      return;
    const on = (callback) => (...args) => {
      const run = () => {
        if (this.#active(attempt))
          callback(...args);
      };
      if (this.#state.phase === "subscribing")
        queueMicrotask(run);
      else
        run();
    };
    let subscription;
    try {
      subscription = this.consumer.subscriptions.create({ channel: this.channelName, ...this.channelParams }, {
        received: on((message) => this.#receive(message, attempt)),
        connected: on(() => this.#connected()),
        disconnected: on(() => this.#lost()),
        rejected: on(() => this.#stop("reject"))
      });
    } catch (error) {
      if (!this.#subscribing(attempt))
        return;
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
  renew(params) {
    if (this.#destroying())
      return;
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
  #active(attempt) {
    const state = this.#state;
    return (state.phase === "connecting" || state.phase === "connected") && state.attempt === attempt;
  }
  #connected() {
    const state = this.#state;
    if (state.phase !== "connecting")
      return;
    this.#state = { ...state, phase: "connected" };
    this.session.resume();
    this.#refreshStatus();
  }
  #lost() {
    const state = this.#state;
    if (state.phase !== "connecting" && state.phase !== "connected")
      return;
    this.#state = { ...state, phase: "connecting" };
    this.session.pause();
    this.#refreshStatus();
  }
  #stop(reason) {
    const state = this.#state;
    if (state.phase === "destroyed")
      return;
    if (state.phase === "stopping") {
      if (reason === "destroy")
        state.reason = reason;
      return;
    }
    if (state.phase === "disconnected" && reason === "disconnect")
      return;
    let finalReason = reason;
    if ("subscription" in state) {
      const stopping = { ...state, phase: "stopping", reason };
      this.#state = stopping;
      this.#unwatchPage();
      this.#presence = this.awareness.getLocalState();
      this.session.removeLocalAwareness();
      this.session.pause();
      this.#unsubscribe(state.subscription);
      if (this.#state !== stopping)
        return;
      finalReason = stopping.reason;
    }
    const destroyed = finalReason === "destroy";
    this.#state = { phase: destroyed ? "destroyed" : "disconnected" };
    if (destroyed)
      this.#destroyOwned();
    else if (finalReason === "reject")
      this.#onError(new Error("subscription rejected by the server"), "rejected");
    this.#refreshStatus();
    if (destroyed)
      this.#statusListeners.clear();
  }
  #destroyOwned() {
    this.session.destroy();
    this.awareness.off("update", this.#onAwarenessUpdate);
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
    if (message && message.ack !== undefined) {
      this.session.acknowledge(message.ack);
      this.#refreshStatus();
      return;
    }
    const awarenessPayload = message && message.awareness;
    const payload = message && (awarenessPayload ?? message.update);
    if (typeof payload !== "string")
      return;
    let frame;
    try {
      frame = fromBase64(payload);
    } catch (error) {
      this.#onError(error, "received");
      return;
    }
    if (awarenessPayload !== undefined && frame[0] !== MessageType.Awareness) {
      this.#onError(new Error("awareness envelope carried a non-awareness frame"), "received");
      return;
    }
    const reply = this.session.receive(frame);
    if (reply && this.#active(attempt))
      this.#send(reply, undefined);
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
    if (status === this.#last.status && pending === this.#last.pending)
      return;
    const event = this.#last = { status, pending };
    if (status === "synced")
      this.#resolveSynced();
    for (const listener of this.#statusListeners) {
      if (this.#last !== event)
        break;
      try {
        listener({ status, pending });
      } catch (error) {
        this.#onError(error, "listener");
      }
    }
  }
  #watchPage() {
    if (typeof window === "undefined" || this.#page)
      return;
    let stashed = null;
    const page = this.#page = {
      hide: () => {
        if (this.#page !== page)
          return;
        stashed = this.awareness.getLocalState();
        this.session.removeLocalAwareness();
      },
      show: (event) => {
        if (this.#page !== page || !event.persisted || !stashed)
          return;
        if (this.awareness.getLocalState() === null)
          this.awareness.setLocalState(stashed);
        stashed = null;
      }
    };
    window.addEventListener("pagehide", this.#page.hide);
    window.addEventListener("pageshow", this.#page.show);
  }
  #unwatchPage() {
    if (!this.#page || typeof window === "undefined")
      return;
    const page = this.#page;
    this.#page = null;
    window.removeEventListener("pagehide", page.hide);
    window.removeEventListener("pageshow", page.show);
  }
  #send(frame, id) {
    const state = this.#state;
    if (!("subscription" in state))
      return;
    const isAwareness = frame[0] === MessageType.Awareness;
    if (state.phase === "stopping" && !isAwareness)
      return;
    const { subscription } = state;
    const update = toBase64(frame);
    const report = (error) => {
      const current = this.#state;
      if ("subscription" in current && current.subscription === subscription)
        this.#onError(error, "send");
    };
    try {
      const result = isAwareness && typeof subscription.whisper === "function" ? subscription.whisper({ awareness: update }) : subscription.send(id === undefined ? { update } : { update, id });
      if (result instanceof Promise)
        result.catch(report);
    } catch (error) {
      report(error);
    }
  }
}

class ProviderAwareness extends Awareness {
  onError;
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
}
// src/document_session.ts
import * as Y3 from "yjs";

// node_modules/lib0/webcrypto.js
var subtle = crypto.subtle;
var getRandomValues = crypto.getRandomValues.bind(crypto);

// node_modules/lib0/random.js
var uint32 = () => getRandomValues(new Uint32Array(1))[0];
var uuidv4Template = [1e7] + -1000 + -4000 + -8000 + -100000000000;
var uuidv4 = () => uuidv4Template.replace(/[018]/g, (c) => (c ^ uint32() & 15 >> c / 4).toString(16));

// src/document_session.ts
var PHASES = {
  open: { state: "open", connects: true, on: { refresh: "refreshing", block: "blocked", close: "closed" } },
  refreshing: { state: "open", connects: false, on: { renew: "renewed", block: "blocked", close: "closed" } },
  renewed: { state: "open", connects: true, on: { accept: "open", block: "blocked", close: "closed" } },
  blocked: { state: "blocked", connects: false, on: { retry: "open", close: "closed" } },
  closed: { state: "closed", connects: false, on: {} }
};
var REFRESH_TIMEOUT_MS = 15000;
var DEFAULT_CHANNEL = "Y::DocumentChannel";
var stores = new WeakMap;
function documentKey(descriptor) {
  return JSON.stringify([descriptor.channel || DEFAULT_CHANNEL, descriptor.grant, descriptor.name]);
}
var storeToken = Symbol("storeToken");
var attachLease = Symbol("attachLease");
var notifyStoreChange = Symbol("notifyStoreChange");

class DocumentSessionStore extends EventTarget {
  consumer;
  static for(consumer) {
    let store = stores.get(consumer);
    if (!store)
      stores.set(consumer, store = new DocumentSessionStore(consumer, storeToken));
    return store;
  }
  #sessions = new Map;
  constructor(consumer, token) {
    super();
    this.consumer = consumer;
    if (token !== storeToken)
      throw new Error("Use DocumentSessionStore.for(consumer)");
  }
  get sessions() {
    return [...this.#sessions.values()];
  }
  acquire(input) {
    if (!input.grant || !input.name)
      throw new Error("A document requires a grant and name");
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
}

class DocumentLease {
  session;
  #controller = new AbortController;
  #onRelease;
  constructor(session, onRelease) {
    this.session = session;
    this.#onRelease = onRelease;
  }
  get signal() {
    return this.#controller.signal;
  }
  setPresence(state) {
    if (!this.signal.aborted)
      this.session.provider.awareness.setLocalState(state);
  }
  release() {
    if (this.signal.aborted)
      return;
    this.#controller.abort();
    this.#onRelease();
  }
}

class DocumentSession {
  store;
  descriptor;
  remove;
  doc = new Y3.Doc;
  provider;
  #lifecycle = { phase: "open" };
  #leases = new Set;
  #retiring;
  #error;
  #dirty = false;
  #settleQueued = false;
  constructor(store, descriptor, remove) {
    this.store = store;
    this.descriptor = descriptor;
    this.remove = remove;
    this.provider = new ActionCableProvider(this.doc, store.consumer, descriptor.channel, {
      grant: descriptor.grant,
      name: descriptor.name,
      session_id: uuidv4()
    }, {
      onError: (error, context) => {
        if (context === "rejected")
          this.#rejected(error);
        else if (this.state !== "closed") {
          this.#error = error;
          this.#changed();
        }
      }
    });
    this.provider.awareness.setLocalState(null);
    this.provider.onStatusChange(({ status }) => {
      if (this.state !== "open")
        return;
      if (status === "connected" || status === "synced")
        this.#transition("accept");
      this.#changed();
    });
  }
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
    if (this.state === "closed")
      throw new Error("Cannot acquire a closed document session");
    const lease = new DocumentLease(this, () => this.#release(lease));
    this.#leases.add(lease);
    this.#changed();
    if (PHASES[this.#lifecycle.phase].connects)
      this.#connect();
    return lease;
  }
  #release(lease) {
    if (!this.#leases.delete(lease))
      return;
    this.#changed();
    if (!this.#leases.size)
      this.provider.awareness.setLocalState(null);
  }
  retry() {
    if (this.#transition("retry"))
      this.#connect();
  }
  discard() {
    this.#close();
  }
  #changed() {
    this.#dirty = true;
    if (this.#settleQueued)
      return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle() {
    this.#settleQueued = false;
    this.#enforce();
    if (!this.#dirty)
      return;
    this.#dirty = false;
    this.store[notifyStoreChange](this);
  }
  #enforce() {
    if (this.state === "closed")
      return;
    if (this.state === "blocked") {
      const retiring = this.#retiring;
      this.#retiring = undefined;
      for (const lease of retiring ?? [])
        lease.release();
      return;
    }
    if (!this.#needed())
      this.#close();
  }
  #connect(grant) {
    try {
      if (grant === undefined)
        this.provider.connect();
      else
        this.provider.renew({ grant });
    } catch (error) {
      this.#transition("block", error);
    }
  }
  #needed() {
    return this.#leases.size > 0 || this.provider.hasPending;
  }
  #transition(event, error) {
    const phase = PHASES[this.#lifecycle.phase].on[event];
    if (!phase)
      return false;
    this.#lifecycle = { phase };
    this.#retiring = phase === "blocked" ? [...this.#leases] : undefined;
    if (event === "retry")
      this.#error = undefined;
    else if (event === "block")
      this.#error = error;
    this.#changed();
    return true;
  }
  #close() {
    if (!this.#transition("close"))
      return;
    this.remove();
    for (const lease of [...this.#leases])
      lease.release();
    this.provider.destroy();
    this.doc.destroy();
  }
  #rejected(error) {
    const url = this.descriptor.refresh;
    if (url && this.#transition("refresh"))
      this.#refresh(url, this.#lifecycle);
    else
      this.#transition("block", error);
  }
  async#refresh(url, attempt) {
    let grant;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      if (this.#lifecycle === attempt)
        this.#transition("block", error);
      return;
    }
    if (this.#lifecycle !== attempt)
      return;
    if (this.#transition("renew"))
      this.#connect(grant);
  }
}
async function fetchGrant(url) {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS)
  });
  if (!response.ok)
    throw new Error(`grant refresh failed: ${response.status}`);
  const body = await response.json();
  const grant = body?.grant;
  if (typeof grant !== "string" || !grant)
    throw new Error("grant refresh returned no grant");
  return grant;
}
// src/turbo_adapter.ts
var adapters = new WeakMap;
var CACHE_EVENTS = ["turbo:before-cache", "turbolinks:before-cache"];
var RENDER_EVENTS = ["turbo:render", "turbo:load", "turbo:fetch-request-error", "turbolinks:render", "turbolinks:load"];
var PREVIEW_ATTRIBUTES = ["data-turbo-preview", "data-turbolinks-preview"];
function registerDocumentMount(mount) {
  let adapter = adapters.get(mount.ownerDocument);
  if (!adapter)
    adapters.set(mount.ownerDocument, adapter = new TurboAdapter(mount.ownerDocument));
  adapter.mounts.add(mount);
  adapter.reconcile();
  return () => {
    adapter.mounts.delete(mount);
    if (!adapter.mounts.size)
      adapter.destroy();
  };
}
class TurboAdapter {
  document;
  mounts = new Set;
  #state = { phase: "active" };
  constructor(document) {
    this.document = document;
    for (const event of CACHE_EVENTS)
      document.addEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS)
      document.addEventListener(event, this.reconcile);
  }
  reconcile = () => {
    if (this.#state.phase !== "active")
      return;
    const html = this.document.documentElement;
    const preview = PREVIEW_ATTRIBUTES.some((attribute) => html?.hasAttribute(attribute));
    for (const mount of this.mounts) {
      if (!mount.isConnected || preview)
        mount.deactivate();
      else
        mount.activate();
    }
  };
  #beforeCache = () => {
    const state = this.#state;
    if (state.phase !== "active")
      return;
    for (const mount of this.mounts)
      mount.deactivate();
    if (this.#state !== state)
      return;
    clearTimeout(state.timer);
    state.timer = setTimeout(() => {
      if (this.#state === state)
        state.timer = setTimeout(this.reconcile, 0);
    }, 0);
  };
  destroy() {
    const state = this.#state;
    if (state.phase === "destroyed")
      return;
    this.#state = { phase: "destroyed" };
    clearTimeout(state.timer);
    adapters.delete(this.document);
    for (const event of CACHE_EVENTS)
      this.document.removeEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS)
      this.document.removeEventListener(event, this.reconcile);
    for (const mount of this.mounts)
      mount.deactivate();
    this.mounts.clear();
  }
}

// src/document_element.ts
var Base = typeof HTMLElement === "undefined" ? class {
} : HTMLElement;
var INERT_ATTRIBUTE = "data-yrby-inert";
var sharedConsumer;
function defaultConsumer() {
  sharedConsumer ??= import("@rails/actioncable").then((actioncable) => actioncable.createConsumer()).catch((error) => {
    sharedConsumer = undefined;
    throw error;
  });
  return sharedConsumer;
}
var assignedConsumer;
var factoryResult;
function loadConsumer(source) {
  if (source == null)
    return defaultConsumer();
  if (typeof source !== "function")
    return Promise.resolve(source);
  if (factoryResult?.factory === source)
    return factoryResult.consumer;
  let consumer;
  try {
    consumer = Promise.resolve(source());
  } catch (error) {
    return Promise.reject(error);
  }
  const entry = { factory: source, consumer };
  factoryResult = entry;
  consumer.catch(() => {
    if (factoryResult === entry)
      factoryResult = undefined;
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
  return session.state === "blocked" ? { error: session.error, session } : undefined;
}

class YrbyDocumentElement extends Base {
  static get consumer() {
    return assignedConsumer;
  }
  static set consumer(value) {
    if (value === assignedConsumer)
      return;
    assignedConsumer = value;
    factoryResult = undefined;
  }
  static observedAttributes = ["grant", "name", "channel"];
  #live = false;
  #attempt;
  #stalledKey;
  #unregister;
  #settleQueued = false;
  #firstSync = deferred();
  get session() {
    const lease = this.#attempt?.lease;
    return lease && !lease.signal.aborted ? lease.session : undefined;
  }
  get doc() {
    return this.session?.doc;
  }
  get provider() {
    return this.session?.provider;
  }
  get whenSynced() {
    return this.#firstSync.promise;
  }
  get current() {
    const detail = this.#attempt?.announced;
    return detail && !detail.signal.aborted ? detail : undefined;
  }
  connectedCallback() {
    this.#stalledKey = undefined;
    if (!this.#attempt)
      this.#holdInert();
    this.#unregister ??= registerDocumentMount(this);
    this.#requestSettle();
  }
  disconnectedCallback() {
    this.#requestSettle();
  }
  attributeChangedCallback(_name, oldValue, newValue) {
    if (oldValue === newValue)
      return;
    this.#stalledKey = undefined;
    this.#abandon();
    this.#requestSettle();
  }
  activate() {
    this.#live = true;
    this.#stalledKey = undefined;
    this.#requestSettle();
  }
  deactivate() {
    this.#live = false;
    this.#abandon();
  }
  retry() {
    const attempt = this.#attempt;
    if (attempt && !attempt.ended && !attempt.lease?.signal.aborted)
      return;
    this.#stalledKey = undefined;
    this.#abandon();
    this.#requestSettle();
  }
  destroy() {
    this.#live = false;
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
    this.#abandon();
  }
  #requestSettle() {
    if (this.#settleQueued)
      return;
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
    const key = this.#live && descriptor.grant && descriptor.name ? documentKey(descriptor) : undefined;
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      this.#abandon();
      this.#requestSettle();
      return;
    }
    if (key === undefined || key === this.#stalledKey)
      return;
    if (!attempt)
      this.#start(key, descriptor);
    else if (attempt.ended)
      this.#stall(attempt.ended.detail);
    else if (attempt.consumer && !attempt.lease)
      this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced)
      this.#announce(attempt);
  }
  #start(key, descriptor) {
    const attempt = { key, descriptor };
    this.#attempt = attempt;
    loadConsumer(YrbyDocumentElement.consumer).then((consumer) => {
      attempt.consumer = consumer;
    }, (error) => {
      attempt.ended = { detail: { error } };
    }).then(() => this.#requestSettle());
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
    session.whenSynced.then(() => {
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
    if (detail)
      this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail }));
  }
  #abandon() {
    const attempt = this.#attempt;
    if (!attempt)
      return;
    this.#attempt = undefined;
    this.#firstSync = deferred();
    this.#holdInert();
    attempt.lease?.release();
  }
  #descriptor() {
    return {
      channel: this.getAttribute("channel") || undefined,
      grant: this.getAttribute("grant") || "",
      name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || undefined
    };
  }
  #holdInert() {
    if (!this.hasAttribute(INERT_ATTRIBUTE))
      this.setAttribute(INERT_ATTRIBUTE, String(this.inert));
    this.inert = true;
  }
  #restoreInert() {
    const saved = this.getAttribute(INERT_ATTRIBUTE);
    if (saved === null)
      return;
    this.inert = saved === "true";
    this.removeAttribute(INERT_ATTRIBUTE);
  }
}
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

//# debugId=D3992DE99C94BF3F64756E2164756E21
//# sourceMappingURL=yrby-client.js.map
