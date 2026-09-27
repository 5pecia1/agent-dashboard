import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// This configuration never reads the host repository's production Wrangler config or secrets.
process.env.CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV = "false";
export default defineConfig(async () => ({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./test/wrangler.jsonc" },
    miniflare: {
      bindings: { TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")) },
    },
  })],
  test: { setupFiles: ["./test/setup.ts"] },
}));
