// Bundle-time adapter: no browser/webview is loaded by the CLI.
import type { NativeHost } from './io';
let connection:NativeHost;
export function setHost(h:NativeHost){connection=h}
export const host=()=>({transport:connection,probe:(path:string)=>connection.result('probe',{path})});
