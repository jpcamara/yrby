import { createClient as createCoreClient } from "./client.js"

/**
 * Bridge the Ruby JSON configuration boundary to the generic WASM client.
 * Supply an existing shared consumer, or a factory for one owned by each client.
 * Ruby options cannot override the Yrs module or consumer ownership policy.
 */
export function createRubyHost({ Y, consumer, createConsumer, onError } = {}) {
  if (!Y?.YDoc || !Y?.Awareness) throw new TypeError("An initialized ywasm module is required")
  if (consumer !== undefined && typeof consumer?.subscriptions?.create !== "function") {
    throw new TypeError("consumer must be an ActionCable-compatible consumer")
  }
  if (consumer === undefined && typeof createConsumer !== "function") {
    throw new TypeError("Supply a consumer or createConsumer factory")
  }
  if (onError !== undefined && typeof onError !== "function") throw new TypeError("onError must be a function")

  return Object.freeze({
    createClient(optionsJSONString = "{}") {
      if (typeof optionsJSONString !== "string") throw new TypeError("Ruby client options must be a JSON string")
      const options = JSON.parse(optionsJSONString)
      if (!options || typeof options !== "object" || Array.isArray(options)) {
        throw new TypeError("Ruby client options must contain a JSON object")
      }
      const owned = consumer === undefined
      const cable = owned ? createConsumer() : consumer
      try {
        return createCoreClient({ ...options, Y, consumer: cable, manageConsumer: owned, onError })
      } catch (error) {
        if (owned) cable?.disconnect?.()
        throw error
      }
    },
  })
}
