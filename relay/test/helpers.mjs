// What the tests share: a Map-backed stand-in for Cloudflare KV, and fetch
// calls that go straight into the worker.
import worker from "../worker.js";

export class FakeKV {
  constructor() {
    this.values = new Map();
    this.ttls = new Map();
  }

  async get(key, type) {
    const value = this.values.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) : value;
  }

  async put(key, value, options) {
    this.values.set(key, value);
    this.ttls.set(key, options?.expirationTtl);
  }

  async delete(key) {
    this.values.delete(key);
  }
}

export const RELAY = "https://relay.test";

/// A fetch that the worker answers, on |kv|.
export function relayFetch(kv) {
  return (url, init = {}) => worker.fetch(new Request(url, init), { SHARES: kv });
}

export function json(body) {
  return { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
}
