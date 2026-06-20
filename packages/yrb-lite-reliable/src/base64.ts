// Convenience codecs for transports that carry binary frames as base64 strings
// (e.g. ActionCable's JSON envelope). Optional -- a binary WebSocket transport
// sends the raw frames directly and never needs these.

export const toBase64 = (bytes: Uint8Array): string =>
  btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));

export const fromBase64 = (str: string): Uint8Array => Uint8Array.from(atob(str), (c) => c.charCodeAt(0));
