// One shared Action Cable consumer for every element that isn't handed one.
// createConsumer() reads the standard `action-cable-url` meta tag (rendered by
// Rails' action_cable_meta_tag) and falls back to /cable, so a server-rendered
// element works with no host JavaScript at all. Shared so multiple forms on a
// page ride one WebSocket, like Rails' own consumer module.
import { createConsumer } from "@rails/actioncable";
let sharedConsumer;
let configuredConsumer;
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
export function setConsumer(consumerOrFactory) {
    configuredConsumer = consumerOrFactory;
}
export function resolveConsumer() {
    if (typeof configuredConsumer === "function")
        configuredConsumer = configuredConsumer();
    return configuredConsumer ?? (sharedConsumer ??= createConsumer());
}
//# sourceMappingURL=consumer.js.map