#!/usr/bin/env bun
import assert from "assert";
import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { Command } from "commander";
import kleur from "kleur";
import { SQL } from "bun";
import Table from "cli-table3";
import { trace, context, SpanStatusCode, SpanKind, ROOT_CONTEXT } from "@opentelemetry/api";
import { BasicTracerProvider, BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";

const program = new Command()
  .name("realtime-check")
  .description("End-to-end Realtime test suite against any Supabase project")
  .option("--project <ref>", "Supabase project ref (required for staging/prod)")
  .option("--publishable-key <key>", "Project publishable (anon) key")
  .option("--secret-key <key>", "Project secret (service role) key")
  .option("--db-password <password>", "Database password (required for staging/prod, or set SUPABASE_DB_PASSWORD)")
  .option("--env <env>", "Environment: local | staging | prod (default: prod)", "prod")
  .option("--domain <domain>", "Email domain for the test user", "example.com")
  .option("--port <port>", "Override URL port (useful for local)")
  .option("--url <url>", "Override project URL (e.g. http://127.0.0.1:54321)")
  .option("--db-url <url>", "Override database URL (e.g. postgresql://postgres:postgres@127.0.0.1:54322/postgres)")
  .option("--json", "Output results as JSON to stdout")
  .option("--otel <endpoint>", "OTLP HTTP endpoint for tracing (e.g. http://localhost:4318)")
  .option("--test <categories>", "Comma-separated list of test categories to run: functional,load,connection,load-postgres-changes,load-presence,load-broadcast,load-broadcast-from-db,load-broadcast-replay,broadcast,broadcast-replay,presence,authorization,postgres-changes,broadcast-changes")
  .parse();

const opts = program.opts();
const ANON_KEY: string = opts.publishableKey ?? process.env.SUPABASE_ANON_KEY;
const SERVICE_KEY: string = opts.secretKey ?? process.env.SUPABASE_SERVICE_ROLE_KEY;
const dbPassword: string = opts.dbPassword ?? process.env.SUPABASE_DB_PASSWORD ?? "";
const { project, env, domain: EMAIL_DOMAIN, port, json: JSON_OUTPUT, test: TEST_FILTER, otel: OTEL_ARG, url: URL_ARG, dbUrl: DB_URL_ARG } = opts;

const TEST_CATEGORIES = TEST_FILTER
  ? TEST_FILTER.split(",").map((s: string) => s.trim().toLowerCase())
  : null;

if (env !== "local" && !project) {
  console.error("--project is required for staging and prod environments");
  process.exit(1);
}
if (env !== "local" && !dbPassword) {
  console.error("SUPABASE_DB_PASSWORD env var is required for staging and prod environments");
  process.exit(1);
}
if (!ANON_KEY) {
  console.error("--publishable-key is required");
  process.exit(1);
}
if (!SERVICE_KEY) {
  console.error("--secret-key is required");
  process.exit(1);
}

const PROJECT_URL = URL_ARG ?? process.env.SUPABASE_URL ?? (() => {
  if (env === "local") return `http://localhost:${port ?? 54321}`;
  if (env === "staging") return `https://${project}.green.supabase.co`;
  return `https://${project}.supabase.co`;
})();

const DB_URL = DB_URL_ARG ?? process.env.SUPABASE_DB_URL ?? (() => {
  const pw = encodeURIComponent(dbPassword ?? "postgres");
  if (env === "local") return `postgresql://postgres:${pw}@localhost:${port ?? 54322}/postgres`;
  if (env === "staging") return `postgresql://postgres:${pw}@db.${project}.green.supabase.co:5432/postgres`;
  return `postgresql://postgres:${pw}@db.${project}.supabase.co:5432/postgres`;
})();

const DB_SSL = env !== "local" ? { rejectUnauthorized: false } : false;

const REALTIME_OPTS = { heartbeatIntervalMs: 5000, timeout: 5000 };
const BROADCAST_CONFIG = { config: { broadcast: { self: true } } };
const EVENT_TIMEOUT_MS = 8000;
const RATE_LIMIT_PAUSE_MS = 2000;
const BROADCAST_API_HEADERS = {
  "Content-Type": "application/json",
  "Authorization": `Bearer ${ANON_KEY}`,
  "apikey": ANON_KEY,
};
const LOAD_MESSAGES = 20;
const LOAD_SETTLE_MS = 5000;
const LOAD_DELIVERY_SLO = 99;

const OTEL_ENDPOINT = OTEL_ARG ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
const OTEL_API_TOKEN = process.env.OTEL_API_TOKEN;

let tracer = trace.getTracer("realtime-check");
let otelProvider: BasicTracerProvider | null = null;

function initOtel() {
  if (!OTEL_ENDPOINT) return;
  const contextManager = new AsyncLocalStorageContextManager();
  contextManager.enable();
  context.setGlobalContextManager(contextManager);
  const provider = new BasicTracerProvider({
    resource: resourceFromAttributes({ [ATTR_SERVICE_NAME]: "realtime-check" }),
    spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({
      url: `${OTEL_ENDPOINT}/v1/traces`,
      ...(OTEL_API_TOKEN ? { headers: { Authorization: `Bearer ${OTEL_API_TOKEN}` } } : {}),
    }))],
  });
  trace.setGlobalTracerProvider(provider);
  tracer = trace.getTracer("realtime-check", "0.0.1");
  otelProvider = provider;
}

async function flushOtel() {
  if (otelProvider) await otelProvider.forceFlush();
}

function patchFetch() {
  if (!OTEL_ENDPOINT) return;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async function tracedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url.includes("/rest/v1") || url.includes("/auth/v1/logout") || url.includes("/auth/v1/admin")) return originalFetch(input, init);
    const method = (init?.method ?? (typeof input === "object" && "method" in input ? input.method : undefined) ?? "GET").toUpperCase();
    const span = tracer.startSpan(`HTTP ${method}`, {
      kind: SpanKind.CLIENT,
      attributes: { "http.method": method, "http.url": url },
    }, context.active());
    return context.with(trace.setSpan(context.active(), span), async () => {
      try {
        const res = await originalFetch(input, init);
        span.setAttribute("http.status_code", res.status);
        if (res.status >= 400) span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${res.status}` });
        return res;
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        span.setStatus({ code: SpanStatusCode.ERROR, message: msg });
        if (e instanceof Error) span.recordException(e);
        throw e;
      } finally {
        span.end();
      }
    });
  }) as typeof fetch;
}


const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const settle = async (getCount: () => number, expected: number, timeoutMs: number) => {
  const deadline = performance.now() + timeoutMs;
  while (getCount() < expected && performance.now() < deadline) await sleep(50);
};
const log = (...args: unknown[]) => JSON_OUTPUT ? process.stderr.write(args.map(String).join(" ") + "\n") : console.log(...args);
const progress = (msg: string) => JSON_OUTPUT ? process.stderr.write(msg) : process.stdout.write(msg);

function measureThroughput(latencies: number[], total: number, label: string, slo: number): Metric[] {
  const delivered = latencies.length;
  const deliveryRate = (delivered / total) * 100;
  const sorted = latencies.slice().sort((a, b) => a - b);
  if (delivered < total) log(`    ${kleur.yellow(`lost ${total - delivered}/${total} ${label}`)}`);
  assert(deliveryRate >= slo, `Delivery rate ${deliveryRate.toFixed(1)}% below ${slo}% SLO`);
  return [
    { label: "delivered", value: deliveryRate, unit: "%" },
    { label: "p50", value: sorted[Math.ceil(sorted.length * 0.5) - 1] ?? 0, unit: "ms" },
    { label: "p95", value: sorted[Math.ceil(sorted.length * 0.95) - 1] ?? 0, unit: "ms" },
    { label: "p99", value: sorted[Math.ceil(sorted.length * 0.99) - 1] ?? 0, unit: "ms" },
  ];
}

type Metric = { label: string; value: number; unit: string };
type TestResult = { suite: string; name: string; passed: boolean; durationMs: number; metrics: Metric[]; error?: string };

let currentSuite = "";
const results: TestResult[] = [];

async function test(name: string, fn: () => Promise<Metric[]>) {
  progress(`  ${name} ... `);
  const start = performance.now();
  const span = tracer.startSpan(name, {
    kind: SpanKind.INTERNAL,
    attributes: { "suite": currentSuite, "env": env, "project.url": PROJECT_URL },
  });
  const testContext = trace.setSpan(ROOT_CONTEXT, span);
  try {
    const metrics = await context.with(testContext, fn);
    const durationMs = performance.now() - start;
    for (const m of metrics) span.setAttribute(`metric.${m.label}`, `${m.value.toFixed(2)}${m.unit}`);
    span.setStatus({ code: SpanStatusCode.OK });
    results.push({ suite: currentSuite, name, passed: true, durationMs, metrics });
    const summary = metrics.map((m) => `${m.label}: ${kleur.cyan(`${m.value.toFixed(m.unit === "%" ? 1 : 0)}${m.unit}`)}`).join("  ");
    log(`${kleur.green("PASS")}  ${kleur.dim(`${durationMs.toFixed(0)}ms`)}${summary ? "  " + summary : ""}`);
  } catch (e: any) {
    const durationMs = performance.now() - start;
    span.setStatus({ code: SpanStatusCode.ERROR, message: e?.message ?? String(e) });
    span.recordException(e);
    results.push({ suite: currentSuite, name, passed: false, durationMs, metrics: [], error: e?.message ?? String(e) });
    log(`${kleur.red("FAIL")}  ${kleur.dim(`${durationMs.toFixed(0)}ms`)}`);
    log(`    ${kleur.red(e?.message ?? e)}`);
  } finally {
    span.end();
  }
}

function suite(name: string) {
  currentSuite = name;
  log(`\n${kleur.bold(name)}`);
}

async function waitFor<T>(getter: () => T | null, label: string): Promise<{ value: T; latencyMs: number }> {
  const span = tracer.startSpan(`wait: ${label}`, { kind: SpanKind.INTERNAL });
  const start = performance.now();
  const deadline = start + EVENT_TIMEOUT_MS;
  let value: T | null;
  return context.with(trace.setSpan(context.active(), span), async () => {
    while ((value = getter()) === null && performance.now() < deadline) await sleep(50);
    const latencyMs = performance.now() - start;
    if (value === null) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: `Timed out` });
      span.end();
      throw new Error(`Timed out waiting for ${label}`);
    }
    span.setAttribute("latency_ms", latencyMs);
    span.setStatus({ code: SpanStatusCode.OK });
    span.end();
    return { value, latencyMs };
  });
}

async function stopClient(supabase: SupabaseClient) {
  await Promise.all([supabase.removeAllChannels(), supabase.auth.stopAutoRefresh()]);
  await supabase.auth.signOut();
}

async function signInUser(supabase: SupabaseClient, email: string, password: string) {
  const span = tracer.startSpan("sign in", { kind: SpanKind.INTERNAL });
  return context.with(trace.setSpan(context.active(), span), async () => {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      span.end();
      throw new Error(`Error signing in: ${error.message}`);
    }
    span.setStatus({ code: SpanStatusCode.OK });
    span.end();
    return data!.session!.access_token;
  });
}

async function waitForSubscribed(channel: ReturnType<SupabaseClient["channel"]>): Promise<number> {
  const span = tracer.startSpan("wait: subscribe", { kind: SpanKind.INTERNAL });
  const start = performance.now();
  const deadline = start + EVENT_TIMEOUT_MS;
  return context.with(trace.setSpan(context.active(), span), async () => {
    while (channel.state === "joining" && performance.now() < deadline) await sleep(50);
    const latencyMs = performance.now() - start;
    if (channel.state !== "joined") {
      span.setStatus({ code: SpanStatusCode.ERROR, message: `state: ${channel.state}` });
      span.end();
      throw new Error(`Channel failed to subscribe (state: ${channel.state})`);
    }
    span.setAttribute("latency_ms", latencyMs);
    span.setStatus({ code: SpanStatusCode.OK });
    span.end();
    return latencyMs;
  });
}

async function waitForPostgresChannel(channel: ReturnType<SupabaseClient["channel"]>): Promise<{ subscribeMs: number; systemMs: number }> {
  const start = performance.now();
  let systemOk = false;
  channel.on("system", "*", ({ status }: { status: string }) => { if (status === "ok") systemOk = true; });
  const subscribeMs = await waitForSubscribed(channel);
  const { latencyMs: systemMs } = await waitFor(() => systemOk ? true : null, "system ok");
  return { subscribeMs, systemMs: performance.now() - start };
}

type TableName = "pg_changes" | "dummy" | "authorization" | "broadcast_changes" | "wallet" | "replay_check";

async function executeInsert(supabase: SupabaseClient, table: TableName): Promise<number> {
  const { data, error } = await supabase.from(table).insert([{ value: crypto.randomUUID() }]).select("id");
  if (error) throw new Error(`Error inserting into ${table}: ${error.message}`);
  return (data as { id: number }[])[0].id;
}

async function executeUpdate(supabase: SupabaseClient, table: TableName, id: number) {
  const { error } = await supabase.from(table).update({ value: crypto.randomUUID() }).eq("id", id);
  if (error) throw new Error(`Error updating ${table}: ${error.message}`);
}

async function executeDelete(supabase: SupabaseClient, table: TableName, id: number) {
  const { error } = await supabase.from(table).delete().eq("id", id);
  if (error) throw new Error(`Error deleting from ${table}: ${error.message}`);
}

async function setup(): Promise<{ userId: string; testUser: { email: string; password: string } }> {
  log(kleur.blue("Setting up database..."));
  const start = performance.now();

  const email = `realtime-check-${crypto.randomUUID()}@${EMAIL_DOMAIN}`;
  const password = crypto.randomUUID();
  log(`  Test user: ${kleur.dim(email)}`);

  const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
  let userId: string;
  try {
    await Promise.all([
      sql`CREATE TABLE IF NOT EXISTS public.pg_changes (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid()
          )`,
      sql`CREATE TABLE IF NOT EXISTS public.dummy (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid()
          )`,
      sql`CREATE TABLE IF NOT EXISTS public.authorization (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid()
          )`,
      sql`CREATE TABLE IF NOT EXISTS public.broadcast_changes (id text PRIMARY KEY, value text NOT NULL)`,
      sql`CREATE TABLE IF NOT EXISTS public.wallet (id text PRIMARY KEY, wallet_id text NOT NULL)`,
      sql`CREATE TABLE IF NOT EXISTS public.replay_check (
            id text PRIMARY KEY,
            topic text NOT NULL,
            event text NOT NULL,
            payload jsonb NOT NULL DEFAULT '{}'
          )`,
    ]);

    await Promise.all([
      sql`INSERT INTO public.wallet (id, wallet_id) VALUES ('1', 'wallet_1') ON CONFLICT (id) DO NOTHING`,
      sql`ALTER TABLE public.dummy DISABLE ROW LEVEL SECURITY`,
      sql`ALTER TABLE public.pg_changes ENABLE ROW LEVEL SECURITY`,
      sql`ALTER TABLE public.authorization ENABLE ROW LEVEL SECURITY`,
      sql`ALTER TABLE public.broadcast_changes ENABLE ROW LEVEL SECURITY`,
      sql`ALTER TABLE public.wallet ENABLE ROW LEVEL SECURITY`,
      sql`ALTER TABLE public.replay_check ENABLE ROW LEVEL SECURITY`,
      sql`ALTER PUBLICATION supabase_realtime ADD TABLE public.pg_changes`.catch(() => {}),
      sql`ALTER PUBLICATION supabase_realtime ADD TABLE public.dummy`.catch(() => {}),
    ]);

    await Promise.all([
      sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated receive on topic' AND tablename = 'messages' AND schemaname = 'realtime') THEN
              CREATE POLICY "authenticated receive on topic" ON "realtime"."messages" AS PERMISSIVE
                FOR SELECT TO authenticated USING (realtime.topic() like 'topic:%');
            END IF;
          END $$`,
      sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated broadcast on topic' AND tablename = 'messages' AND schemaname = 'realtime') THEN
              CREATE POLICY "authenticated broadcast on topic" ON "realtime"."messages" AS PERMISSIVE
                FOR INSERT TO authenticated WITH CHECK (realtime.topic() like 'topic:%');
            END IF;
          END $$`,
      sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'allow authenticated users all access' AND tablename = 'pg_changes' AND schemaname = 'public') THEN
              CREATE POLICY "allow authenticated users all access" ON "public"."pg_changes" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE);
            END IF;
          END $$`,
      sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated have full access to read on broadcast_changes' AND tablename = 'broadcast_changes' AND schemaname = 'public') THEN
              CREATE POLICY "authenticated have full access to read on broadcast_changes" ON "public"."broadcast_changes" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE);
            END IF;
          END $$`,
      sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated have full access to replay_check' AND tablename = 'replay_check' AND schemaname = 'public') THEN
              CREATE POLICY "authenticated have full access to replay_check" ON "public"."replay_check" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);
            END IF;
          END $$`,
    ]);

    await sql`
      CREATE OR REPLACE FUNCTION broadcast_changes_for_table_trigger() RETURNS TRIGGER AS $$
      DECLARE topic text;
      BEGIN
        topic = 'topic:test';
        PERFORM realtime.broadcast_changes(topic, TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD, TG_LEVEL);
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
    `;

    await sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'broadcast_changes_for_table_public_broadcast_changes_trigger') THEN
          CREATE TRIGGER broadcast_changes_for_table_public_broadcast_changes_trigger
            AFTER INSERT OR UPDATE OR DELETE ON broadcast_changes
            FOR EACH ROW EXECUTE FUNCTION broadcast_changes_for_table_trigger();
        END IF;
      END $$
    `;

    await sql`
      CREATE OR REPLACE FUNCTION replay_check_trigger() RETURNS TRIGGER AS $$
      BEGIN
        PERFORM realtime.send(NEW.payload, NEW.event, NEW.topic, true);
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
    `;

    await sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'replay_check_send_trigger') THEN
          CREATE TRIGGER replay_check_send_trigger
            AFTER INSERT ON public.replay_check
            FOR EACH ROW EXECUTE FUNCTION replay_check_trigger();
        END IF;
      END $$
    `;

    const admin = createClient(PROJECT_URL, SERVICE_KEY);
    const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (error) throw new Error(`Failed to create test user: ${error.message}`);
    userId = data.user.id;
  } finally {
    await sql.close();
  }

  log(`${kleur.green("Setup complete")} ${kleur.dim(`(${(performance.now() - start).toFixed(0)}ms)`)}`);
  return { userId: userId!, testUser: { email, password } };
}

async function cleanup(userId: string) {
  const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
  try {
    await sql`DELETE FROM auth.users WHERE id = ${userId}`;
  } finally {
    await sql.close();
  }
  log(kleur.dim("Test user cleaned up."));
}

async function runConnectionTest() {
  suite("connection");

  await test("first connect latency", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      const channel = supabase.channel("topic:" + crypto.randomUUID()).subscribe();
      const connectMs = await waitForSubscribed(channel);
      return [{ label: "connect", value: connectMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await test("broadcast message throughput", async () => {
    const MESSAGES = 50;
    const SETTLE_MS = 3000;
    const DELIVERY_SLO = 99;
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      const topic = "topic:" + crypto.randomUUID();
      const event = "load";
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForSubscribed(channel);

      for (let i = 0; i < MESSAGES; i++) {
        sendTimes.set(i, performance.now());
        await channel.send({ type: "broadcast", event, payload: { seq: i } });
      }

      await settle(() => latencies.length, MESSAGES, SETTLE_MS);

      return measureThroughput(latencies, MESSAGES, "messages", DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runLoadPostgresChangesTests(testUser: { email: string; password: string }) {
  suite("load-postgres-changes");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("postgres changes system message latency", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes" }, () => {})
        .subscribe();
      const { systemMs } = await waitForPostgresChannel(channel);
      return [{ label: "system", value: systemMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("postgres changes INSERT throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.new.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForPostgresChannel(channel);

      for (let i = 0; i < LOAD_MESSAGES; i++) {
        const t = performance.now();
        const id = await executeInsert(supabase, "pg_changes");
        sendTimes.set(id, t);
      }

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "INSERT events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("postgres changes UPDATE throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const ids = await Promise.all(Array.from({ length: LOAD_MESSAGES }, () => executeInsert(supabase, "pg_changes")));

      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.new.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForPostgresChannel(channel);

      await Promise.all(ids.map((id) => {
        sendTimes.set(id, performance.now());
        return executeUpdate(supabase, "pg_changes", id);
      }));

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "UPDATE events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("postgres changes DELETE throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const ids = await Promise.all(Array.from({ length: LOAD_MESSAGES }, () => executeInsert(supabase, "pg_changes")));

      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.old.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForPostgresChannel(channel);

      await Promise.all(ids.map((id) => {
        sendTimes.set(id, performance.now());
        return executeDelete(supabase, "pg_changes", id);
      }));

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "DELETE events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runLoadPresenceTests() {
  suite("load-presence");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("presence join throughput", async () => {
    const CLIENTS = 10;
    const observer = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    const senders: ReturnType<typeof createClient>[] = [];
    try {
      const topic = "topic:" + crypto.randomUUID();
      const trackTimes = new Map<string, number>();
      const latencies: number[] = [];

      const observerChannel = observer
        .channel(topic, { config: { broadcast: { self: true }, presence: { key: "observer" } } })
        .on("presence", { event: "join" }, (e) => {
          if (e.key === "observer") return;
          const t = trackTimes.get(e.key);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();
      await waitForSubscribed(observerChannel);

      const clients = Array.from({ length: CLIENTS }, (_, i) => ({
        client: createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS }),
        key: `client-${i}`,
      }));
      senders.push(...clients.map((c) => c.client));

      const channels = await Promise.all(clients.map(async ({ client, key }) => {
        const ch = client.channel(topic, { config: { presence: { key } } }).subscribe();
        await waitForSubscribed(ch);
        return { ch, key };
      }));

      await Promise.all(channels.map(({ ch, key }) => {
        trackTimes.set(key, performance.now());
        return ch.track({ key });
      }));

      await settle(() => latencies.length, CLIENTS, LOAD_SETTLE_MS);

      return measureThroughput(latencies, CLIENTS, "presence joins", LOAD_DELIVERY_SLO);
    } finally {
      await Promise.all(senders.map((c) => stopClient(c)));
      await stopClient(observer);
    }
  });
}

async function runLoadBroadcastFromDbTests(testUser: { email: string; password: string }) {
  suite("load-broadcast-from-db");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("broadcast from database throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const sendTimes = new Map<string, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel("topic:test", { config: { private: true } })
        .on("broadcast", { event: "INSERT" }, (res) => {
          const t = sendTimes.get(res.payload.record.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForSubscribed(channel);

      await Promise.all(Array.from({ length: LOAD_MESSAGES }, async () => {
        const id = crypto.randomUUID();
        sendTimes.set(id, performance.now());
        await supabase.from("broadcast_changes").insert({ id, value: crypto.randomUUID() });
      }));

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      await supabase.from("broadcast_changes").delete().in("id", [...sendTimes.keys()]);

      return measureThroughput(latencies, LOAD_MESSAGES, "broadcast-from-db events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runLoadBroadcastTests() {
  suite("load-broadcast");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("broadcast self throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      const event = "load";
      const topic = "topic:" + crypto.randomUUID();
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForSubscribed(channel);

      for (let i = 0; i < LOAD_MESSAGES; i++) {
        sendTimes.set(i, performance.now());
        await channel.send({ type: "broadcast", event, payload: { seq: i } });
      }

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "broadcast events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("broadcast API endpoint throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      const event = "load";
      const topic = "topic:" + crypto.randomUUID();
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        })
        .subscribe();

      await waitForSubscribed(channel);

      await Promise.all(Array.from({ length: LOAD_MESSAGES }, async (_, i) => {
        sendTimes.set(i, performance.now());
        const res = await fetch(`${PROJECT_URL}/realtime/v1/api/broadcast`, {
          method: "POST",
          headers: BROADCAST_API_HEADERS,
          body: JSON.stringify({ messages: [{ topic, event, payload: { seq: i } }] }),
        });
        if (!res.ok) throw new Error(`Broadcast API returned ${res.status}`);
      }));

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "broadcast API events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runLoadBroadcastReplayTests(testUser: { email: string; password: string }) {
  suite("load-broadcast-replay");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("broadcast replay throughput", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();

      const since = Date.now() - 1000;
      await Promise.all(Array.from({ length: LOAD_MESSAGES }, (_, i) =>
        supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { seq: i } })
      ));

      const latencies: number[] = [];
      const replayStart = performance.now();
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 25 } } },
      }).on("broadcast", { event }, () => {
        latencies.push(performance.now() - replayStart);
      }).subscribe();
      await waitForSubscribed(receiver);

      await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

      return measureThroughput(latencies, LOAD_MESSAGES, "replayed broadcast events", LOAD_DELIVERY_SLO);
    } finally {
      await stopClient(supabase);
    }
  });
}


async function runBroadcastTests() {
  suite("broadcast extension");

  await test("user is able to receive self broadcast", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      let result: any = null;
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();
      const expectedPayload = { message: crypto.randomUUID() };

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => (result = payload))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      await channel.send({ type: "broadcast", event, payload: expectedPayload });
      const { latencyMs: eventMs } = await waitFor(() => result, "broadcast event");

      assert.deepStrictEqual(result, expectedPayload);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await test("user is able to use the endpoint to broadcast", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      let result: any = null;
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();
      const expectedPayload = { message: crypto.randomUUID() };

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => (result = payload))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);

      const res = await fetch(`${PROJECT_URL}/realtime/v1/api/broadcast`, {
        method: "POST",
        headers: BROADCAST_API_HEADERS,
        body: JSON.stringify({ messages: [{ topic, event, payload: expectedPayload }] }),
      });
      if (!res.ok) throw new Error(`Broadcast API returned ${res.status}`);

      const { latencyMs: eventMs } = await waitFor(() => result, "broadcast event");
      assert.deepStrictEqual(result, expectedPayload);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runPresenceTests(testUser: { email: string; password: string }) {
  suite("presence extension");

  await test("user is able to receive presence updates", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      let joinEvent: any = null;
      const topic = "topic:" + crypto.randomUUID();
      const message = crypto.randomUUID();
      const key = crypto.randomUUID();

      const channel = supabase
        .channel(topic, { config: { broadcast: { self: true }, presence: { key } } })
        .on("presence", { event: "join" }, (e) => (joinEvent = e))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      const trackStart = performance.now();
      if (await channel.track({ message }, { timeout: 5000 }) === "timed out") throw new Error("track() timed out");
      const trackMs = performance.now() - trackStart;
      const { latencyMs: eventMs } = await waitFor(() => joinEvent, "presence join");

      assert.strictEqual(joinEvent.key, key);
      assert.strictEqual(joinEvent.newPresences[0].message, message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "track", value: trackMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user is able to receive presence updates on private channels", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);

      let joinEvent: any = null;
      const topic = "topic:" + crypto.randomUUID();
      const message = crypto.randomUUID();
      const key = crypto.randomUUID();

      const channel = supabase
        .channel(topic, { config: { private: true, broadcast: { self: true }, presence: { key } } })
        .on("presence", { event: "join" }, (e) => (joinEvent = e))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      const trackStart = performance.now();
      if (await channel.track({ message }, { timeout: 5000 }) === "timed out") throw new Error("track() timed out");
      const trackMs = performance.now() - trackStart;
      const { latencyMs: eventMs } = await waitFor(() => joinEvent, "presence join");

      assert.strictEqual(joinEvent.key, key);
      assert.strictEqual(joinEvent.newPresences[0].message, message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "track", value: trackMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runAuthorizationTests(testUser: { email: string; password: string }) {
  suite("authorization check");

  await test("user using private channel cannot connect without permissions", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      let errMessage: any = null;
      const topic = "topic:" + crypto.randomUUID();

      supabase
        .channel(topic, { config: { private: true } })
        .subscribe((status: string, err: any) => {
          if (status === "CHANNEL_ERROR") errMessage = err.message;
        });

      const { latencyMs: rejectMs } = await waitFor(() => errMessage, "CHANNEL_ERROR");
      assert.strictEqual(
        errMessage,
        `"Unauthorized: You do not have permissions to read from this Channel topic: ${topic}"`
      );
      return [{ label: "rejection", value: rejectMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user using private channel can connect with enough permissions", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);

      let connected = false;
      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), { config: { private: true } })
        .subscribe((status: string) => { if (status === "SUBSCRIBED") connected = true; });

      const subscribeMs = await waitForSubscribed(channel);
      assert.strictEqual(connected, true);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runBroadcastChangesTests(testUser: { email: string; password: string }) {
  suite("broadcast changes");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives INSERT broadcast change", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const id = crypto.randomUUID();
      const value = crypto.randomUUID();
      let result: any = null;

      const channel = supabase
        .channel("topic:test", { config: { private: true } })
        .on("broadcast", { event: "INSERT" }, (res) => (result = res))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      await supabase.from("broadcast_changes").insert({ value, id });
      const { latencyMs: eventMs } = await waitFor(() => result, "INSERT event");

      assert.strictEqual(result.payload.record.id, id);
      assert.strictEqual(result.payload.record.value, value);
      assert.strictEqual(result.payload.old_record, null);
      assert.strictEqual(result.payload.operation, "INSERT");
      assert.strictEqual(result.payload.schema, "public");
      assert.strictEqual(result.payload.table, "broadcast_changes");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives UPDATE broadcast change", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const id = crypto.randomUUID();
      const originalValue = crypto.randomUUID();
      const updatedValue = crypto.randomUUID();
      await supabase.from("broadcast_changes").insert({ value: originalValue, id });
      let result: any = null;

      const channel = supabase
        .channel("topic:test", { config: { private: true } })
        .on("broadcast", { event: "UPDATE" }, (res) => (result = res))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      await supabase.from("broadcast_changes").update({ value: updatedValue }).eq("id", id);
      const { latencyMs: eventMs } = await waitFor(() => result, "UPDATE event");

      assert.strictEqual(result.payload.record.id, id);
      assert.strictEqual(result.payload.record.value, updatedValue);
      assert.strictEqual(result.payload.old_record.id, id);
      assert.strictEqual(result.payload.old_record.value, originalValue);
      assert.strictEqual(result.payload.operation, "UPDATE");
      assert.strictEqual(result.payload.schema, "public");
      assert.strictEqual(result.payload.table, "broadcast_changes");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives DELETE broadcast change", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const id = crypto.randomUUID();
      const value = crypto.randomUUID();
      await supabase.from("broadcast_changes").insert({ value, id });
      let result: any = null;

      const channel = supabase
        .channel("topic:test", { config: { private: true } })
        .on("broadcast", { event: "DELETE" }, (res) => (result = res))
        .subscribe();

      const subscribeMs = await waitForSubscribed(channel);
      await supabase.from("broadcast_changes").delete().eq("id", id);
      const { latencyMs: eventMs } = await waitFor(() => result, "DELETE event");

      assert.strictEqual(result.payload.record, null);
      assert.strictEqual(result.payload.old_record.id, id);
      assert.strictEqual(result.payload.old_record.value, value);
      assert.strictEqual(result.payload.operation, "DELETE");
      assert.strictEqual(result.payload.schema, "public");
      assert.strictEqual(result.payload.table, "broadcast_changes");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runPostgresChangesTests(testUser: { email: string; password: string }) {
  suite("postgres changes extension");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives INSERT events with filter", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);

      let result: unknown = null;
      const previousId = await executeInsert(supabase, "pg_changes");
      await executeInsert(supabase, "dummy");

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "INSERT", schema: "public", table: "pg_changes", filter: `id=eq.${previousId + 1}` },
          (payload) => (result = payload))
        .subscribe();

      const { subscribeMs } = await waitForPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes");
      await executeInsert(supabase, "dummy");
      const { latencyMs: eventMs } = await waitFor(() => result, "INSERT event");

      assert.strictEqual(result.eventType, "INSERT");
      assert.strictEqual(result.new.id, previousId + 1);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives UPDATE events with filter", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);

      let result: unknown = null;
      const mainId = await executeInsert(supabase, "pg_changes");
      const fakeId = await executeInsert(supabase, "pg_changes");
      const dummyId = await executeInsert(supabase, "dummy");

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "UPDATE", schema: "public", table: "pg_changes", filter: `id=eq.${mainId}` },
          (payload) => (result = payload))
        .subscribe();

      const { subscribeMs } = await waitForPostgresChannel(channel);
      await Promise.all([
        executeUpdate(supabase, "pg_changes", mainId),
        executeUpdate(supabase, "pg_changes", fakeId),
        executeUpdate(supabase, "dummy", dummyId),
      ]);
      const { latencyMs: eventMs } = await waitFor(() => result, "UPDATE event");

      assert.strictEqual(result.eventType, "UPDATE");
      assert.strictEqual(result.new.id, mainId);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives DELETE events with filter", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);

      let result: unknown = null;
      const mainId = await executeInsert(supabase, "pg_changes");
      const fakeId = await executeInsert(supabase, "pg_changes");
      const dummyId = await executeInsert(supabase, "dummy");

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "DELETE", schema: "public", table: "pg_changes", filter: `id=eq.${mainId}` },
          (payload) => (result = payload))
        .subscribe();

      const { subscribeMs } = await waitForPostgresChannel(channel);
      await Promise.all([
        executeDelete(supabase, "pg_changes", mainId),
        executeDelete(supabase, "pg_changes", fakeId),
        executeDelete(supabase, "dummy", dummyId),
      ]);
      const { latencyMs: eventMs } = await waitFor(() => result, "DELETE event");

      assert.strictEqual(result.eventType, "DELETE");
      assert.strictEqual(result.old.id, mainId);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives INSERT, UPDATE and DELETE concurrently", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      let insertResult: unknown = null, updateResult: unknown = null, deleteResult: unknown = null;

      const insertId = await executeInsert(supabase, "pg_changes");
      const updateId = await executeInsert(supabase, "pg_changes");
      const deleteId = await executeInsert(supabase, "pg_changes");

      const channel = supabase
        .channel("topic:" + crypto.randomUUID(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: `id=eq.${insertId + 3}` }, (p) => (insertResult = p))
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "pg_changes", filter: `id=eq.${updateId}` }, (p) => (updateResult = p))
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "pg_changes", filter: `id=eq.${deleteId}` }, (p) => (deleteResult = p))
        .subscribe();

      const { subscribeMs } = await waitForPostgresChannel(channel);

      await Promise.all([
        executeInsert(supabase, "pg_changes"),
        executeUpdate(supabase, "pg_changes", updateId),
        executeDelete(supabase, "pg_changes", deleteId),
      ]);

      const [{ latencyMs: insertMs }, { latencyMs: updateMs }, { latencyMs: deleteMs }] = await Promise.all([
        waitFor(() => insertResult, "INSERT event"),
        waitFor(() => updateResult, "UPDATE event"),
        waitFor(() => deleteResult, "DELETE event"),
      ]);

      assert.strictEqual(insertResult.eventType, "INSERT");
      assert.strictEqual(updateResult.eventType, "UPDATE");
      assert.strictEqual(deleteResult.eventType, "DELETE");
      return [
        { label: "subscribe", value: subscribeMs, unit: "ms" },
        { label: "INSERT", value: insertMs, unit: "ms" },
        { label: "UPDATE", value: updateMs, unit: "ms" },
        { label: "DELETE", value: deleteMs, unit: "ms" },
      ];
    } finally {
      await stopClient(supabase);
    }
  });
}

async function runBroadcastReplayTests(testUser: { email: string; password: string }) {
  suite("broadcast replay");

  await test("replayed messages are delivered on join", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();
      const payload = { message: crypto.randomUUID() };

      const since = Date.now() - 1000;
      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload });

      await sleep(500);

      let result: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 1 } } },
      }).on("broadcast", { event }, (msg) => (result = msg.payload)).subscribe();
      const subscribeMs = await waitForSubscribed(receiver);

      const { latencyMs: replayMs } = await waitFor(() => result, "replayed broadcast event");

      assert.strictEqual(result.message, payload.message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "replay", value: replayMs, unit: "ms" }];
    } finally {
      await stopClient(supabase);
    }
  });

  await test("replayed messages carry meta.replayed flag", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();

      const since = Date.now() - 1000;
      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { value: 1 } });

      await sleep(500);

      let receivedMeta: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 1 } } },
      }).on("broadcast", { event }, (msg) => (receivedMeta = msg.meta)).subscribe();
      await waitForSubscribed(receiver);

      await waitFor(() => receivedMeta, "replayed broadcast meta");

      assert.strictEqual(receivedMeta?.replayed, true);
      return [];
    } finally {
      await stopClient(supabase);
    }
  });

  await test("messages before since are not replayed", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      await signInUser(supabase, testUser.email, testUser.password);
      const event = crypto.randomUUID();
      const topic = "topic:" + crypto.randomUUID();

      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { value: "old" } });

      const since = Date.now();

      let result: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 25 } } },
      }).on("broadcast", { event }, (msg) => (result = msg.payload)).subscribe();
      await waitForSubscribed(receiver);

      await sleep(500);

      assert.strictEqual(result, null);
      return [];
    } finally {
      await stopClient(supabase);
    }
  });
}

function printSummary(totalMs: number) {
  const passed = results.filter((r) => r.passed);
  const failed = results.filter((r) => !r.passed);
  const suites = [...new Set(results.map((r) => r.suite))];

  if (JSON_OUTPUT) {
    const slis: Record<string, Record<string, { value: number; unit: string }>> = {};
    for (const r of passed) {
      for (const m of r.metrics) {
        const key = `${r.suite} / ${r.name}`;
        slis[key] ??= {};
        slis[key][m.label] = { value: m.value, unit: m.unit };
      }
    }
    const output = {
      passed: failed.length === 0,
      durationMs: Math.round(totalMs),
      summary: { total: results.length, passed: passed.length, failed: failed.length },
      slis,
      suites: Object.fromEntries(suites.map((suite) => {
        const suiteResults = results.filter((r) => r.suite === suite);
        return [suite, {
          passed: suiteResults.every((r) => r.passed),
          tests: suiteResults.map((r) => ({
            name: r.name,
            passed: r.passed,
            durationMs: Math.round(r.durationMs),
            ...(r.error ? { error: r.error } : {}),
            slis: Object.fromEntries(r.metrics.map((m) => [m.label, { value: m.value, unit: m.unit }])),
          })),
        }];
      })),
    };
    process.stdout.write(JSON.stringify(output, null, 2) + "\n");
    return;
  }

  for (const suite of suites) {
    const suiteResults = results.filter((r) => r.suite === suite);
    const suiteLabels = [...new Set(suiteResults.flatMap((r) => r.metrics.map((m) => m.label)))];

    const table = new Table({
      head: [kleur.bold(suite), kleur.dim("status"), kleur.dim("total"), ...suiteLabels.map(kleur.dim)],
      style: { border: ["dim"], head: [] },
    });

    for (const r of suiteResults) {
      table.push([
        `  ${r.name}`,
        r.passed ? kleur.green("PASS") : kleur.red("FAIL"),
        kleur.dim(`${r.durationMs.toFixed(0)}ms`),
        ...suiteLabels.map((label) => {
          const m = r.metrics.find((x) => x.label === label);
          return m ? kleur.cyan(`${m.value.toFixed(m.unit === "%" ? 1 : 0)}${m.unit}`) : kleur.dim("-");
        }),
      ]);
    }

    log(`
${table.toString()}`);
  }

  log(`
${kleur.bold(`${passed.length} passed, ${failed.length} failed`)}  ${kleur.dim(`total ${(totalMs / 1000).toFixed(2)}s`)}`);

  if (failed.length > 0) {
    log("\nFailed:");
    for (const r of failed) {
      log(`  ${kleur.red("✗")} ${r.suite} / ${r.name}`);
      if (r.error) log(`    ${kleur.dim(r.error)}`);
    }
  }
}

const SUITES: Record<string, (testUser: { email: string; password: string }) => Promise<void>> = {
  "connection": () => runConnectionTest(),
  "load-postgres-changes": (u) => runLoadPostgresChangesTests(u),
  "load-presence": () => runLoadPresenceTests(),
  "load-broadcast": () => runLoadBroadcastTests(),
  "load-broadcast-from-db": (u) => runLoadBroadcastFromDbTests(u),
  "load-broadcast-replay": (u) => runLoadBroadcastReplayTests(u),
  "broadcast": () => runBroadcastTests(),
  "broadcast-replay": (u) => runBroadcastReplayTests(u),
  "presence": (u) => runPresenceTests(u),
  "authorization": (u) => runAuthorizationTests(u),
  "postgres-changes": (u) => runPostgresChangesTests(u),
  "broadcast-changes": (u) => runBroadcastChangesTests(u),
};

const LOAD_SUITES = Object.keys(SUITES).filter((k) => k.startsWith("load"));
const FUNCTIONAL_SUITES = Object.keys(SUITES).filter((k) => !k.startsWith("load"));

async function main() {
  initOtel();
  patchFetch();

  log(kleur.bold("Realtime Check"));
  log(`Project: ${PROJECT_URL}`);
  log(`Env: ${env}  Email domain: ${EMAIL_DOMAIN}\n`);
  if (OTEL_ENDPOINT) log(kleur.dim(`Tracing → ${OTEL_ENDPOINT}\n`));

  const activeCategories = TEST_CATEGORIES
    ? TEST_CATEGORIES.flatMap((c: string) => {
        if (c === "functional") return FUNCTIONAL_SUITES;
        if (c === "load") return LOAD_SUITES;
        return [c];
      })
    : null;

  if (activeCategories) {
    const unknown = activeCategories.filter((c: string) => !(c in SUITES));
    if (unknown.length > 0) {
      const valid = ["functional", "load", ...Object.keys(SUITES)].join(", ");
      log(`Unknown test categories: ${unknown.join(", ")}\nValid categories: ${valid}`);
      process.exit(1);
    }
    log(`Running categories: ${activeCategories.join(", ")}\n`);
  }

  const suitesToRun = activeCategories
    ? Object.entries(SUITES).filter(([key]) => activeCategories.includes(key))
    : Object.entries(SUITES);

  const { userId, testUser } = await setup();

  const start = performance.now();
  try {
    for (const [, fn] of suitesToRun) await fn(testUser);
  } finally {
    await cleanup(userId);
  }

  printSummary(performance.now() - start);
  await flushOtel();

  if (results.some((r) => !r.passed)) process.exit(1);
}

main().catch((e) => {
  console.error(kleur.red("Fatal error:"), e.message);
  process.exit(1);
});
