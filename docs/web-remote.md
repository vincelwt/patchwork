# Web remote

A phone-first web app for managing Pi Desktop threads and schedules away from the Mac. It is
static HTML/CSS/JS, bundled into the app and served by `pi-deskd`, the daemon described in
[`docs/daemon-api.md`](daemon-api.md). This document covers the parts that document doesn't:
how to turn the listener on, where the token lives, how to reach it from a phone safely, and
what the security model actually guarantees.

## Enabling it

The daemon's Unix socket (used by the Mac app and the `pidesk` CLI) is always on. The web remote
needs the second, opt-in transport: a loopback TCP listener.

```bash
pidesk remote enable            # starts listening on 127.0.0.1:7717
pidesk remote enable --port 8080
pidesk remote url                # prints http://127.0.0.1:<port>
pidesk remote token              # prints the bearer token
pidesk remote disable
```

`pidesk daemon status` shows whether the daemon and the remote listener are both running. If the
daemon isn't running yet, `pidesk daemon start` (or just opening Pi Desktop once, since it
installs the LaunchAgent) starts it.

## Where the token lives

```text
~/Library/Application Support/Pi Desktop/daemon-token
```

32 random bytes, base64url-encoded, file mode `0600` (owner read/write only). The daemon
generates it the first time `remote enable` runs and reuses it after that; `pidesk remote token`
just prints the existing file. Every request to the loopback listener — including the page load
for the web app itself and the `/v1/events` stream — must carry:

```text
Authorization: Bearer <token>
```

There is no session/cookie concept. Losing the token (e.g. suspecting it leaked) means deleting
the file and re-running `pidesk remote enable`, which mints a new one and immediately
invalidates the old one.

## Using it on the phone

1. On the Mac: `pidesk remote enable`, then `pidesk remote token` and copy it somewhere you can
   paste from (or just keep the Terminal window open).
2. Get traffic from the phone to `127.0.0.1:<port>` on the Mac. The daemon will not do this part
   for you — see the two options below.
3. On the phone, open the tunnel's URL, paste the token into the sign-in screen, and add the
   page to the home screen (Safari: Share → Add to Home Screen) for an app-like icon and no
   browser chrome.

The daemon deliberately never opens a public listener itself and never ships a tunnel client.
That is a hard line, not a missing feature: a background daemon that can start Pi runs is a bad
thing to expose to the internet by accident, so the only way traffic reaches it from outside
`127.0.0.1` is a tunnel *you* explicitly start, which you can stop the moment you're done.

### Option A — SSH tunnel (no new software, if you already SSH into the Mac)

From the phone (Termius, Blink, iSH, or any SSH client with port forwarding):

```bash
ssh -L 7717:127.0.0.1:7717 you@your-mac.local
```

Then browse to `http://127.0.0.1:7717` **on the phone** — the SSH client is forwarding that local
port to the Mac's loopback port through the encrypted SSH connection. Nothing is listening on
the network beyond the SSH server you already trust. Works over your home network; works over
the internet too if the Mac is SSH-reachable (a VPN back to home, or a always-on SSH endpoint).

### Option B — Cloudflare Tunnel (works from anywhere, no port forwarding)

On the Mac, `cloudflared` creates an outbound-only connection to Cloudflare's edge and gives you
a URL:

```bash
brew install cloudflared
cloudflared tunnel --url http://127.0.0.1:7717
```

That prints a `https://*.trycloudflare.com` URL you can open from the phone on any network — no
router configuration, no open inbound port on your home network. Cloudflare terminates TLS for
you, which matters because the daemon itself only ever speaks plain HTTP on loopback. For
anything longer-lived than a quick check, use a named tunnel with `cloudflared` authenticated to
your own domain instead of the throwaway quick-tunnel URL, and keep the bearer token as the real
access control either way — the tunnel gets you a reachable URL, not authorization.

Either option is "on when you need it": start it before you leave, stop it (`Ctrl-C`, or
`pidesk remote disable` on the Mac) when you're back. The token stays useless to anyone without
the tunnel, and the tunnel stays useless to anyone without the token.

## Security model, in plain language

- **Nothing is exposed by default.** `pidesk remote enable` is opt-in; a fresh install has no
  network listener beyond the filesystem-permissioned Unix socket.
- **Two layers, not one.** Reaching the daemon from a phone requires *both* a tunnel you started
  and the bearer token. A leaked tunnel URL alone gets an attacker a login screen, nothing more —
  Chrome DevTools, `curl`, or a nosy person on the same Cloudflare edge cannot act without the
  token. A leaked token alone is useless without also being able to reach `127.0.0.1:<port>` on
  the Mac, i.e. through your tunnel.
- **The token is a bearer credential, not a password.** Anyone who has it can do anything the API
  allows — read threads, send messages, run schedules — until you rotate it. Treat it like an SSH
  private key: store it in a password manager on the phone, not in a notes app, and never share a
  screenshot that includes it.
- **The client never logs it.** The web app keeps the token in `localStorage` only, sends it
  solely as the `Authorization` header, and never writes it to the console, an error message, or
  a URL/query string (the SSE stream is fetched with a normal header, not a `?token=` query
  param, specifically to avoid it ending up in server access logs).
- **Sign-out is real.** The visible sign-out button clears `localStorage` and returns to the
  token screen; nothing is cached server-side per browser.
- **A 401 always means "sign in again."** Every request path — page load, API call, or the event
  stream — treats an unauthorized response as "the token is gone or wrong" and drops back to the
  token screen rather than retrying silently.
- **The daemon is still the source of truth for what's allowed.** The web remote has no
  privileges the CLI or the app don't also have; it is one more caller of the same API in
  `docs/daemon-api.md`, bound by the same execution model (concurrency limits, `skipIfRunning`,
  quiet hours, run history).

## What the web app actually is

`Sources/PiDeskWeb/Site/` — plain HTML/CSS/JS, no build step, no framework, no npm, no CDN.
`PiDeskWeb.asset(for:)` (Swift, `Sources/PiDeskWeb/PiDeskWeb.swift`) serves it: known files by
path, everything else falls back to `index.html` so the client-side router (`/`, `/thread/:id`,
`/new`, `/schedules`, `/schedules/:id`, `/schedules/new`) works on a hard refresh or a deep link,
and `/v1/*` is always left for the daemon's own router. See that file's doc comment for the exact
contract the daemon implements against.
