// Minimal ambient types for the optional peer: the element dynamic-imports it
// only when no consumer was assigned, so the package compiles (and its tests
// run) without @rails/actioncable installed.
declare module "@rails/actioncable" {
  export function createConsumer(url?: string): unknown;
}
