# Patchwork for phones

A managed Expo app for iOS and Android. It is not an agent host: a phone shows
a workspace it has been paired into and stays out of the way.

```bash
npm install
npm run typecheck   # tsc, including ../client
npm run ios         # generate/build the native iOS development app
npm run android     # generate/build the native Android development app
npm start           # reconnect an installed development build to Metro
npm run export      # bundle both platforms, no simulator needed
```

Two things are not obvious:

- Wire types and the API client come from `../client` through the `@client/*`
  alias. That is outside this folder, so `metro.config.js` watches it and
  `tsconfig.json` maps it. Anything platform specific stays out of `client`.
- `ios/` and `android/` are generated (`npx expo prebuild`) and git-ignored.
  Configure native details in `app.json`, not in the generated projects.

Sessions live in `src/lib/session.ts`. Pair from Desktop with its short-lived
QR code; the relay exchanges it once for a separate, revocable mobile token.
Only `savePairedSession({ baseUrl, token })` writes that credential, and it
lives in SecureStore. A physical phone needs the workspace relay at a public
HTTPS/WSS URL. An embedded `127.0.0.1` relay is reachable only from that Mac.

The client covers chat and DMs, threads, reactions and images; inbox questions;
tasks and discussions; agents, hosts and runs; steering/cancellation;
automations and history; members, invites and paired devices. It caches the
last workspace and drafts in AsyncStorage, reconnects with event sequence
resume, and rejects mutations while offline. Mobile tokens cannot register an
execution host, so a phone can control work but never run an agent.
