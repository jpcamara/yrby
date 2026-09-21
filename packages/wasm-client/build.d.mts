export const YWASM_VERSION: "0.28.0"
export interface BrowserBuildOptions {
  ywasmDir: string
  outputFile: string
  wasmURL?: string
}
export interface BrowserBuildAssets {
  version: string
  bindingsPath: string
  wasmPath: string
  licensePath: string
}
/** Node-only pinned ywasm loader transform. Does not bundle or copy runtime binaries. */
export function buildYwasmBrowser(options: BrowserBuildOptions): Promise<BrowserBuildAssets>
