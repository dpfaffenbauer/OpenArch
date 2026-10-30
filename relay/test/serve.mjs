// The relay on a plain Node server, its data in memory, for the apps'
// self-tests (ios.yml): node relay/test/serve.mjs [port]
import { createServer } from "node:http";
import { Buffer } from "node:buffer";
import { handle } from "../relay.js";

const port = Number(process.argv[2] ?? 8787);
const shares = new Map();
const storage = {
  get: async (id) => shares.get(id) ?? null,
  put: async (id, record) => void shares.set(id, record),
};

createServer(async (incoming, outgoing) => {
  const chunks = [];
  for await (const chunk of incoming) chunks.push(chunk);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const headers = Object.entries(incoming.headers).map(([name, value]) => [name, String(value)]);
  const request = new Request(`http://localhost:${port}${incoming.url}`, { method: incoming.method, headers, body });
  const response = await handle(request, storage);
  console.log(`${incoming.method} ${incoming.url} ${response.status}`);
  outgoing.writeHead(response.status, Object.fromEntries(response.headers));
  outgoing.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, () => console.log(`relay on http://localhost:${port}`));
