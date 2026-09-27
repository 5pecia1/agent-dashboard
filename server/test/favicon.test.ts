import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

// SHA-256 of app/flutter_app/web/favicon.png. The server inlines those bytes.
const FAVICON_SHA256 = "239ae0048550773c0e21767570462af4b69bfb7f8fda5acbe14237477e493b3e";

async function call(path: string): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`), env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function sha256(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

describe("server favicon", () => {
  it("GET /favicon.png returns the app icon without authentication", async () => {
    const response = await call("/favicon.png");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("image/png");
    expect(await sha256(await response.arrayBuffer())).toBe(FAVICON_SHA256);
  });

  it("GET /favicon.ico returns the same PNG", async () => {
    const png = await call("/favicon.png");
    const ico = await call("/favicon.ico");
    expect(ico.status).toBe(200);
    expect(ico.headers.get("Content-Type")).toBe("image/png");
    expect(new Uint8Array(await ico.arrayBuffer())).toEqual(new Uint8Array(await png.arrayBuffer()));
  });
});
