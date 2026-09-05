import type { CableConsumer } from "yrby-client";
/**
 * The app-wide default consumer, for transports the element can't build
 * itself: call once at boot, before forms mount. Accepts the consumer or a
 * function returning one, resolved lazily on first use.
 *
 *   import { createConsumer } from "@anycable/web";
 *   import { setConsumer } from "yrby-forms";
 *   setConsumer(() => createConsumer());
 *
 * A consumer assigned directly on a <collaborative-form> element still wins.
 */
export declare function setConsumer(consumerOrFactory: CableConsumer | (() => CableConsumer)): void;
export declare function resolveConsumer(): CableConsumer;
//# sourceMappingURL=consumer.d.ts.map