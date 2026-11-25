// Minimal ambient types for the optional peer dependency. The element imports
// it dynamically only when no consumer has been assigned, so the package
// compiles and its tests run without @rails/actioncable installed.
declare module "@rails/actioncable" {
  export function createConsumer(url?: string): unknown;
}
