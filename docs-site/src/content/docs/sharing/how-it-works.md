---
title: "How sharing works"
description: "Why a shared link is its own key, what the relay and openarch.app can and cannot see, and how live shares stay up to date."
---

Sharing in OpenArch needs no account, no login and no address book. The link
itself is the permission: whoever has it can read what it shows, nobody else
can, and that includes the server that passes live shares on. Only the Mac or
iPhone that made a share can change it. This page explains how; the full
format, threat model and relay API are in
[docs/sharing.md](https://github.com/dpfaffenbauer/OpenArch/blob/main/docs/sharing.md)
on GitHub.

OpenArch for Mac, OpenArch for iPhone and iPad, the web page at
`openarch.app/s/` and the relay all use the same format.

## The key is in the link

A share link looks like this:

```text
https://openarch.app/s/#1.l.Qm9vb2tzaGFyZTEyMzQ1Ng.kAAECAwQ…
```

Everything after the `#` is the link's fragment. Browsers never send the
fragment to a server, so `openarch.app` never sees it. It holds what the
apps need to open the share:

- the kind of link: `l` for live, `s` for a snapshot
- for a live share, its ID; for a snapshot, the encrypted bookmarks themselves
- the 32-byte key, or, with a password, the key locked with that password
- for a live share on another relay than `share.openarch.app`, that relay's
  address

`openarch://share#…` carries the same fragment and opens the app directly.

## Encryption

Before it leaves your device, a share is written as JSON (its name, icon,
color and the tree of tabs and folders), compressed and encrypted with
AES-256-GCM under a random key. When a share is opened, only `http` and
`https` links are kept, so a share cannot slip in `javascript:` or `file:`
links.

A **snapshot** puts the encrypted bookmarks into the link. No server is
involved, and the link never changes.

A **live share** (**Aktuell halten**) puts them on the relay. The link holds
only the share's ID and the key.

## Only the owner can change a share

When you make a live share, your Mac or iPhone creates an Ed25519 key pair
for it. The private key never leaves the device; it is kept with the share's
other keys in a file only your user can read (`Shares.json` next to the
library).

- **The share ID is the hash of the public key.** Nobody can take over an
  ID, and the relay can check uploads without knowing anybody.
- **Every upload is signed** with the private key. The relay accepts it only
  with a valid signature and a version higher than the stored one.
- **The apps check too.** Before they decrypt an update, they check the
  signature, that the ID matches the key, and that the version did not go
  down. The version is bound into the encryption as well. A relay that
  handed out forged or old content would be noticed.

## Passwords

With **Mit Passwort schützen**, the key in the link is locked with your
password: PBKDF2-HMAC-SHA256 with 600,000 rounds derives a key that wraps
the share's key. That way the link and the password can go different ways,
say the link by mail and the password by phone. Opening a password-protected
share takes about half a second.

## What the relay sees

Live shares go through a small relay at `share.openarch.app`, a Cloudflare
Worker that stores one signed, encrypted envelope per share in Cloudflare's
key-value store.

| The relay sees | The relay does not see |
| --- | --- |
| the share ID and its public key | the bookmarks, their names or how many there are |
| the version, and when it changes | the key, which is only in the link |
| how large the encrypted data is | who you are: there are no accounts and no cookies |
| the IP addresses that upload or read a share, and when | |

It does not log what is uploaded. It cannot change a share, since every
upload needs the owner's signature.

## What openarch.app sees

`openarch.app` is a static site. For someone without OpenArch, the page at
`openarch.app/s/` decrypts the bookmarks in their browser:

- The server only gets a request for the page, never the fragment with the
  key.
- The page loads nothing but its own files, sends no referrer, and talks
  only to the share's relay to fetch a live share.
- It asks for the password, if there is one, and decrypts in the browser.

## How live shares stay up to date

- **The owner uploads** about a second after the folder or space changes.
  Each upload is a new version.
- **Followers check every five minutes.** The Mac checks while OpenArch
  runs. The iPhone and iPad check every five minutes while OpenArch is open,
  and also when it comes to the front, when the sidebar opens and when you
  pull down the sidebar. A check asks the relay only whether there is a newer
  version.
- **Unchanged shares are uploaded again once a month**, because the relay
  forgets shares that have not been updated for 400 days.

**Ending a share** sends a signed request to the relay. It keeps a marker,
so that an old upload cannot bring the share back, and answers that the share
has ended. Everyone who added it keeps the last state.

## Limits

- An upload to the relay is at most 256 KiB.
- A share opens with at most 4 MiB of bookmarks once decompressed, 5,000
  entries and 16 levels of folders.

## What is not protected

- Whoever has the link (and the password, if there is one) can read the
  share and pass it on.
- The relay sees which IP addresses ask for which share ID, when, and how
  large it is.
- Ending a live share stops updates. It cannot take back what people already
  have.

## Your own relay

A company, or anyone, can run their own relay: it is `relay/` in OpenArch's
source, about 200 lines, as a Cloudflare Worker or anywhere that runs it. Set
it on the Mac in **Settings › Teilen › Teilen-Server**, on the iPhone and iPad
in **Einstellungen › Teilen-Server**. New live shares then go there, and their
links name that relay, so the people they are sent to need nothing set up. A
relay must speak `https` (plain `http` only on `localhost`, for testing). How
to deploy it is in the
[relay's README](https://github.com/dpfaffenbauer/OpenArch/blob/main/relay/README.md).
