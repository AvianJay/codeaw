import { gzipSync } from "node:zlib";
import type WebSocket from "ws";

/** Binary gzip is explicitly opted into by Codeaw clients. ACP-only clients keep text. */
export function enableGzipFrames(socket: WebSocket): void {
  const send = socket.send.bind(socket);
  socket.send = ((data: unknown, ...args: any[]) => {
    if (typeof data === "string" && Buffer.byteLength(data) >= 1024) {
      const compressed = gzipSync(data, { level: 3 });
      if (compressed.length < Buffer.byteLength(data)) {
        const callback = args.find(arg => typeof arg === "function");
        // Do not compress the gzip again if the runtime also supports permessage-deflate.
        return send(compressed, { binary: true, compress: false }, callback);
      }
    }
    return (send as any)(data, ...args);
  }) as WebSocket["send"];
}
