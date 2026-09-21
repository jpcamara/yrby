import type { CableConsumer, ClientOptions, Presence, WasmClient } from "./client.js"

export interface RubyClientOptions {
  channel?: string
  params?: Record<string, unknown>
  localState?: Presence | null
  resendInterval?: number
}
export interface RubyHostOptions {
  Y: ClientOptions["Y"]
  consumer?: CableConsumer
  createConsumer?: () => CableConsumer
  onError?: ClientOptions["onError"]
}
export interface RubyHost {
  createClient(optionsJSONString?: string): WasmClient
}
/** Supply an existing shared consumer or a factory for consumers owned per client. */
export function createRubyHost(options: RubyHostOptions): Readonly<RubyHost>
