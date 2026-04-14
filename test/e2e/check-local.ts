#!/usr/bin/env bun
/**
 * Quick smoke-check for a locally running Realtime docker stack.
 *
 * Usage:
 *   bun run check-local.ts
 *
 * Expects docker-compose up to be running (make start or docker compose up).
 * All config is hard-coded to match docker-compose.yml defaults.
 */

import { RealtimeClient } from "@supabase/realtime-js";

const BASE_URL = "http://localhost:4000";
const JWT_SECRET = "dc447559-996d-4761-a306-f47a5eab1623";
const TENANT = "realtime-dev";
const DASHBOARD_USER = "admin";
const DASHBOARD_PASSWORD = "admin";

// ---- minimal JWT (HS256) without external deps -------------------------

async function signJwt(payload: object): Promise<string> {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, "");
  const body = btoa(JSON.stringify({ ...payload, exp: Math.floor(Date.now() / 1000) + 3600 }))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${header}.${body}`));
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${header}.${body}.${sigB64}`;
}

// ---- test runner -------------------------------------------------------

type Result = { name: string; passed: boolean; error?: string; ms: number };
const results: Result[] = [];

async function check(name: string, fn: () => Promise<void>) {
  const start = performance.now();
  try {
    await fn();
    const ms = Math.round(performance.now() - start);
    results.push({ name, passed: true, ms });
    console.log(`  ✓  ${name}  (${ms}ms)`);
  } catch (e: any) {
    const ms = Math.round(performance.now() - start);
    results.push({ name, passed: false, error: e?.message ?? String(e), ms });
    console.log(`  ✗  ${name}  (${ms}ms)`);
    console.log(`       ${e?.message ?? e}`);
  }
}

// ---- helpers -----------------------------------------------------------

function section(title: string) {
  console.log(`\n${title}`);
}

async function waitFor<T>(
  fn: () => T | null,
  timeoutMs = 8000
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let v: T | null;
  while ((v = fn()) === null && Date.now() < deadline) await Bun.sleep(50);
  if (v === null) throw new Error("Timed out");
  return v;
}

// ---- test suites -------------------------------------------------------

async function checkHealthcheck() {
  section("Healthcheck");
  await check("GET /healthcheck returns 200", async () => {
    const res = await fetch(`${BASE_URL}/healthcheck`);
    if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
  });
}

async function checkDashboard() {
  section("Dashboard");
  const auth = btoa(`${DASHBOARD_USER}:${DASHBOARD_PASSWORD}`);
  const headers = { Authorization: `Basic ${auth}` };

  await check("GET /admin/dashboard reachable", async () => {
    const res = await fetch(`${BASE_URL}/admin/dashboard`, { headers });
    if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
  });

  await check("GET /admin/dashboard/node_info reachable", async () => {
    const res = await fetch(`${BASE_URL}/admin/dashboard/node_info`, { headers });
    if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
    const html = await res.text();
    if (!html.includes("Node Info")) throw new Error("'Node Info' not found in response");
  });

  await check("node_info shows Region row", async () => {
    const res = await fetch(`${BASE_URL}/admin/dashboard/node_info`, { headers });
    const html = await res.text();
    if (!html.includes("Region")) throw new Error("'Region' not found in node_info page");
  });

  await check("node_info shows Read Replica row", async () => {
    const res = await fetch(`${BASE_URL}/admin/dashboard/node_info`, { headers });
    const html = await res.text();
    if (!html.includes("Read Replica")) throw new Error("'Read Replica' not found in node_info page");
  });
}

async function checkRealtime() {
  section("Realtime channels");

  // The server derives the tenant external_id from the first segment of the request host.
  // Use realtime-dev.localhost so the host resolves to 127.0.0.1 while the first
  // segment matches the seeded tenant name.
  const anonToken = await signJwt({ role: "anon" });
  const client = new RealtimeClient(`ws://${TENANT}.localhost:4000/socket`, {
    heartbeatIntervalMs: 5000,
    timeout: 8000,
    params: { apikey: anonToken },
  });

  client.connect();

  await check("broadcast: self-echo", async () => {
    let received: unknown = null;
    const ch = client.channel("check-broadcast", { config: { broadcast: { self: true } } });
    ch.on("broadcast", { event: "ping" }, (p: unknown) => { received = p; });

    await new Promise<void>((res, rej) => {
      const t = setTimeout(() => rej(new Error("subscribe timeout")), 8000);
      ch.subscribe((status: string) => {
        if (status === "SUBSCRIBED") { clearTimeout(t); res(); }
        if (status === "CHANNEL_ERROR") { clearTimeout(t); rej(new Error("channel error")); }
      });
    });

    ch.send({ type: "broadcast", event: "ping", payload: { v: 1 } });
    await waitFor(() => received);
    client.removeChannel(ch);
  });

  await check("presence: track & sync", async () => {
    let synced = false;
    const ch = client.channel("check-presence");
    ch.on("presence", { event: "sync" }, () => { synced = true; });

    await new Promise<void>((res, rej) => {
      const t = setTimeout(() => rej(new Error("subscribe timeout")), 8000);
      ch.subscribe(async (status: string) => {
        if (status === "SUBSCRIBED") {
          clearTimeout(t);
          await ch.track({ user: "check-local" });
          res();
        }
      });
    });

    await waitFor(() => synced ? true : null);
    client.removeChannel(ch);
  });

  client.disconnect();
}

// ---- main --------------------------------------------------------------

console.log(`Realtime local smoke-check → ${BASE_URL}\n`);

await checkHealthcheck();
await checkDashboard();
await checkRealtime();

const passed = results.filter((r) => r.passed).length;
const failed = results.filter((r) => !r.passed).length;

console.log(`\n${passed} passed, ${failed} failed\n`);
if (failed > 0) process.exit(1);
