import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/// Wire types and the portable API live outside this app so the mobile client
/// can use the same source.
const client = fileURLToPath(new URL("../client", import.meta.url));

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  resolve: {
    alias: { "@client": client },
  },
  server: {
    port: 5273,
    strictPort: true,
    // Dev serves from outside the app folder because `@client` is a sibling.
    fs: { allow: [".", client] },
  },
  build: {
    target: "safari15",
    sourcemap: false,
  },
});
