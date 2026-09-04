// @rails/actioncable ships no type declarations. The one function this
// package uses returns a consumer satisfying yrby-client's CableConsumer
// slice (subscriptions.create).
declare module "@rails/actioncable" {
  import type { CableConsumer } from "yrby-client";
  export function createConsumer(url?: string): CableConsumer;
}
