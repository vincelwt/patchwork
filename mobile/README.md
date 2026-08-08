# Patchwork for phones

A managed Expo app for iOS and Android. It is not an agent host: a phone shows
a workspace it has been paired into and stays out of the way.

```bash
npm install
npm run typecheck   # tsc, including ../client
npm start           # then press i or a
npm run export      # bundle both platforms, no simulator needed
```

Two things are not obvious:

- Wire types and the API client come from `../client` through the `@client/*`
  alias. That is outside this folder, so `metro.config.js` watches it and
  `tsconfig.json` maps it. Anything platform specific stays out of `client`.
- `ios/` and `android/` are generated (`npx expo prebuild`) and git-ignored.
  Configure native details in `app.json`, not in the generated projects.

Sessions live in `src/lib/session.ts`. A pairing flow will call
`savePairedSession({ baseUrl, token })` with what Desktop hands over, and that
is the only writer of credentials in the app. Until pairing exists the app
opens on the signed-out screen.
