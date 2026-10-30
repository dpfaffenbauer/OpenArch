# Sharing bookmarks without an account

OpenArch shares a pinned folder or a space's pinned tabs as a link. There is
no account, no login and no address book. The link itself is the permission:
whoever has it can read what it shows, nobody else can, and that includes the
server that passes live shares on. Only the device that made a share can
change it.

The same format is used by OpenArch for Mac, OpenArch for iPhone and iPad, the
web page at `openarch.app/s/` (for people without OpenArch) and the relay.

## Two kinds of links

- **Snapshot.** The bookmarks travel inside the link, encrypted. No server is
  involved; the link does not change later. Good for a handful of links in a
  chat or by AirDrop.
- **Live** ("Aktuell halten"). The link holds a share ID and the key. The
  encrypted, signed bookmarks lie on the relay (`share.openarch.app`, or your
  own). Changes on the sharing Mac or iPhone reach everyone who added the
  share, every few minutes. Good for keeping your iPhone in step with your
  Mac, or a team folder.

Either kind can also be protected with a password, so that the link and the
password can go different ways.

## What is protected, and how

| Threat | Protection |
| --- | --- |
| The relay (or anyone who copies its storage) reads the bookmarks | It only ever sees AES-256-GCM ciphertext. The key is in the link's `#fragment`, which browsers never send to a server. |
| Someone overwrites or deletes a share | Every upload is signed with the share's Ed25519 key, which never leaves the owner's device. The share ID is the hash of the public key, so the relay can check the signature without knowing anybody. |
| The relay hands out forged or old content | Clients check the signature, the ID and the version themselves; the version is part of the encrypted data's associated data and must not go down. |
| A share contains `javascript:` or `file:` links | Clients keep `http` and `https` links only. |
| A share is huge | Uploads are limited to 256 KiB, decompressed payloads to 4 MiB, trees to 5000 entries and 16 levels. |
| A link travels through an untrusted channel | Optional password: PBKDF2-HMAC-SHA256 with 600 000 rounds wraps the key. |

What is not protected: whoever has the link (and the password) can read the
share and pass it on, and the relay sees which IP addresses ask for which
share ID, when, and how large it is. Ending a live share stops updates; it
cannot take back what people already have.

## Format, version 1

All base64 is base64url without padding (RFC 4648 §5). All strings are UTF-8.

### Payload

Before encryption, a share is this JSON:

```json
{
  "v": 1,
  "kind": "folder",
  "name": "Design",
  "icon": "paintbrush.fill",
  "color": "#7B6CF6",
  "updated": "2026-10-30T10:00:00Z",
  "items": [
    { "id": "6F1C…", "title": "Figma", "url": "https://figma.com/" },
    { "id": "A0B2…", "title": "Inspiration", "icon": "star.fill", "children": [
      { "id": "C3D4…", "title": "Dribbble", "url": "https://dribbble.com/" }
    ] }
  ]
}
```

- `kind` is `folder` or `space`. `icon` is an SF Symbol name or an emoji;
  `color` (spaces) is `#RRGGBB`. `icon`, `color` and `updated` are optional.
- An entry with `children` is a folder, otherwise a tab with `url`. `id` is a
  UUID that stays the same while the entry exists, so that receivers can keep
  their open tabs across updates.
- Readers ignore unknown keys and refuse `v` other than 1.

The plaintext that gets encrypted is one format byte followed by the JSON:
`0x00` JSON as is, `0x01` JSON compressed with raw DEFLATE (RFC 1951, no zlib
header). Writers use `0x01`.

### Encryption

`blob = nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`, AES-256-GCM with the
32-byte content key and this associated data (ASCII):

- snapshot: `openarch-share-v1 snapshot`
- live: `openarch-share-v1 live <id> <version>` (version in decimal)

### Live shares: keys, ID, envelope

The owner makes an Ed25519 key pair. The share ID is
`base64url(SHA-256(public key)[0..<16])`, 22 characters.

The relay stores one envelope per ID:

```json
{ "v": 1, "pk": "<public key, 32 bytes>", "version": 7, "blob": "<blob>", "sig": "<64 bytes>" }
```

`sig` is the Ed25519 signature over the ASCII string
`openarch-share-v1 put <id> <version> <blob>`, where `<blob>` is the base64url
text exactly as in the envelope. `version` is an integer from 1 to 2^53 − 1 and
grows with every upload.

### Password

`salt` is 16 random bytes; `wrapKey = PBKDF2-HMAC-SHA256(NFC(password), salt,
600000 rounds, 32 bytes)`; `wrapped = AES-256-GCM(wrapKey, content key,
associated data "openarch-share-v1 key")` as `nonce ‖ ciphertext ‖ tag`
(60 bytes).

### Link

```
https://openarch.app/s/#<fragment>
openarch://share#<fragment>                 (opens the app directly)

fragment = "1" "." mode "." locator "." keyslot [ "." relay ]
mode     = "l"                                  live
         | "s"                                  snapshot
locator  = <id>                                 live
         | base64url(blob)                      snapshot
keyslot  = "k" base64url(content key)           32 bytes
         | "p" base64url(salt ‖ wrapped)        16 + 60 bytes
relay    = "r" base64url(relay base URL)        live, only if not the default
```

Example (live, default relay):
`https://openarch.app/s/#1.l.Qm9vb2tzaGFyZTEyMzQ1Ng.kAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8`

## Relay API

Base URL: `https://share.openarch.app` (or your own, see `relay/`).

- `GET /v1/shares/<id>`: `200` with the envelope, `304` if `If-None-Match`
  names the current version (ETag `"<version>"`), `404` unknown, `410` ended.
- `PUT /v1/shares/<id>`: the envelope as body. The relay checks that the ID
  is the hash of `pk`, the signature, and that `version` is higher than the
  stored one. `200 {"version": n}`; `400` malformed, `403` bad signature or
  ID, `409` version not higher, `410` ended, `413` larger than 256 KiB.
- `DELETE /v1/shares/<id>`: body `{ "version": n, "sig": "…" }`, `sig` over
  `openarch-share-v1 delete <id> <n>` with `n` higher than the stored version.
  The relay keeps a marker with that version, so old uploads cannot bring the
  share back. `200`; errors as for `PUT`.
- Every response has `Cache-Control: no-store` and
  `Access-Control-Allow-Origin: *`; credentials are never used. Shares not
  updated for 400 days expire; owners re-upload unchanged shares once a month.
