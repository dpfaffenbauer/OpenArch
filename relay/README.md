# OpenArch share relay

The small server behind OpenArch's live shares ("Aktuell halten"): it keeps
one signed, encrypted envelope per share and hands it to whoever asks for
it. The format and the API are in [docs/sharing.md](../docs/sharing.md).

- `relay.js`: the relay itself, about 200 lines, on any storage with `get`
  and `put`.
- `worker.js`: the same as a Cloudflare Worker on a KV namespace.
- `test/`: `node --test test/*.test.mjs` (Node 22, no packages to install).
  `test/make-vectors.mjs` writes the test vectors for the Swift side.

## What the relay sees, and what it does not

It sees, per share: the share ID, the public key, the version, the size of
the encrypted data, when it changes, and the IP addresses that upload or
read it. It does not see the bookmarks, their names or their number: the
key to them is in the link's `#fragment`, which never reaches a server.

It cannot change a share either. An upload is accepted only with a
signature by the share's private key, which never leaves the device that
made the share, and the share ID is the hash of the public key, so nobody
can take over an ID. Apps check the signature and the version themselves as
well, so a relay that lied would be noticed.

No accounts, no cookies, no logs of what is uploaded. Shares not updated for
400 days expire (OpenArch re-uploads its shares once a month).

## Trying it on this computer

`npx wrangler@3 dev --port 8787` runs the relay with a local store, no account
needed. The apps take `http://localhost:8787` as their relay, in Settings and
in links; other addresses must be `https`. Their self-tests share, follow, change
and end a live share against it:

```sh
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest --relay http://localhost:8787
xcrun simctl launch --console-pty booted at.pfaffenbauer.openarch -selftest -relay http://localhost:8787
```

The web page only talks to `https` relays, so to try a live link there, put a
tunnel in front: `cloudflared tunnel --url http://localhost:8787`.

## Deploy

With a Cloudflare account and [wrangler](https://developers.cloudflare.com/workers/wrangler/):

```sh
cd relay
npx wrangler@3 login
npx wrangler@3 kv namespace create SHARES   # put the id it prints into wrangler.toml
npx wrangler@3 deploy
```

The relay is then at `https://openarch-share-relay.<account>.workers.dev`.
For `share.openarch.app`, OpenArch's default, uncomment the route in
`wrangler.toml` (the domain's DNS must be on Cloudflare).

`.github/workflows/relay.yml` deploys from `main` when the repository has
the secrets `CLOUDFLARE_API_TOKEN` (a token with *Workers Scripts: Edit*
and *Workers KV Storage: Edit*) and `CLOUDFLARE_ACCOUNT_ID`.

Worth setting up in Cloudflare as well: a rate-limiting rule on `PUT` and
`DELETE` for `/v1/shares/*`, since anyone may create shares.

### Limits of the free plan

Workers KV on the free plan allows about 1000 writes and 100 000 reads a
day. Every change to a live share is one write; every app that follows a
share reads it every five minutes while it runs (about 300 reads a day per
follower). For more, use the paid plan.

## Your own relay

Companies and anyone else can run their own: deploy it as above under
another name or domain, and choose it in OpenArch's settings (on the Mac
Einstellungen › Teilen › Teilen-Server, on the iPhone Einstellungen ›
Teilen-Server). Links made there name that relay, so the people they are sent to
need nothing set up. The relay only has to answer the API in
`docs/sharing.md`; `relay.js` runs anywhere with `fetch`-style `Request` and
`Response` objects and WebCrypto with Ed25519.
