// The Cloudflare Worker: the relay (relay.js) on a KV namespace bound as
// SHARES. See README.md for deploying it.
import { handle, kvStorage } from "./relay.js";

export default {
  async fetch(request, env) {
    try {
      return await handle(request, kvStorage(env.SHARES));
    } catch {
      // Storage hiccups and the like; never with the request's body.
      return new Response(JSON.stringify({ error: "relay error" }), {
        status: 500,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store" },
      });
    }
  },
};
