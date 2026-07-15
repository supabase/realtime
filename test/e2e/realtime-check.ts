#!/usr/bin/env bun
import assert from "assert";
import { createClient, SupabaseClient, postgresChangesFilter } from "@supabase/supabase-js";
import { Command } from "commander";
import kleur from "kleur";
import { SQL } from "bun";
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
  .option("--db-password <password>", "Database password (required for staging/prod)")
  .option("--env <env>", "Environment: local | staging | development | prod | production (default: prod)", "prod")
  .option("--domain <domain>", "Email domain for the test user", "example.com")
  .option("--port <port>", "Override URL port (useful for local)")
  .option("--url <url>", "Override project URL (e.g. http://127.0.0.1:54321)")
  .option("--db-url <url>", "Override database URL (e.g. postgresql://postgres:postgres@127.0.0.1:54322/postgres)")
  .option("--json", "Output results as JSON to stdout")
  .option("--otel <endpoint>", "OTLP HTTP endpoint for tracing (e.g. http://localhost:4318)")
  .option("--otel-token <token>", "Bearer token for authenticated OTLP endpoints")
  .option("--test <categories>", "Comma-separated list of test categories to run: functional,load,connection,load-postgres-changes,load-presence,load-broadcast,load-broadcast-from-db,load-broadcast-replay,broadcast,broadcast-replay,presence,authorization,postgres-changes,postgres-changes-filters,broadcast-changes,broadcast-binary")
  .option("--debug", "Enable Realtime client debug mode (sets log level to info and enables console logging)")
  .parse();

const opts = program.opts();
const ANON_KEY: string = opts.publishableKey;
const SERVICE_KEY: string = opts.secretKey;
const dbPassword: string = opts.dbPassword ?? "";
const { project, domain: EMAIL_DOMAIN, port, json: JSON_OUTPUT, test: TEST_FILTER, otel: OTEL_ARG, otelToken: OTEL_API_TOKEN, url: URL_ARG, dbUrl: DB_URL_ARG, debug: DEBUG } = opts;
const env: string = opts.env === "production" ? "prod" : opts.env === "development" ? "staging" : opts.env;

const TEST_CATEGORIES = TEST_FILTER
  ? TEST_FILTER.split(",").map((s: string) => s.trim().toLowerCase())
  : null;

if (env !== "local" && !project && !(URL_ARG && DB_URL_ARG)) {
  console.error("--project is required (or provide both --url and --db-url)");
  process.exit(1);
}
if (!ANON_KEY) {
  console.error("--publishable-key is required");
  process.exit(1);
}

const PROJECT_URL = URL_ARG ?? (() => {
  if (env === "local") return `http://localhost:${port ?? 54321}`;
  if (env === "staging") return `https://${project}.supabase.red`;
  return `https://${project}.supabase.co`;
})();

const DB_URL = DB_URL_ARG ?? (() => {
  const pw = encodeURIComponent(dbPassword ?? "postgres");
  if (env === "local") return `postgresql://postgres:${pw}@localhost:${port ?? 54322}/postgres`;
  if (env === "staging") return `postgresql://postgres:${pw}@db.${project}.supabase.red:5432/postgres`;
  return `postgresql://postgres:${pw}@db.${project}.supabase.co:5432/postgres`;
})();

const DB_SSL = env !== "local" ? { rejectUnauthorized: false } : false;

const realtimeLogger = DEBUG
  ? (kind: string, msg: string, data?: any) => {
      if (data !== undefined) console.error(`[realtime] ${kind}: ${msg}`, data);
      else console.error(`[realtime] ${kind}: ${msg}`);
    }
  : undefined;

const REALTIME_OPTS = { ...(DEBUG ? { logger: realtimeLogger, logLevel: "info" } : {}) };
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

const OTEL_ENDPOINT = OTEL_ARG;

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
const randomTopic = () => "topic:" + crypto.randomUUID();
const fmtSqlResult = (result: any[]) => {
  const count = (result as any).count ?? result.length;
  return result.length > 0 ? `count=${count} rows=${JSON.stringify(result)}` : `count=${count}`;
};
const runSql = (label: string, query: Promise<any[]>): Promise<any[]> =>
  query
    .then((r) => { log(kleur.dim(`setup:   ${label} ok (${fmtSqlResult(r)})`)); return r; })
    .catch((e: unknown) => { log(kleur.red(`setup:   ${label} FAILED: ${e instanceof Error ? e.message : String(e)}`)); throw e; });
const settle = async (getCount: () => number, expected: number, timeoutMs: number) => {
  const deadline = performance.now() + timeoutMs;
  while (getCount() < expected && performance.now() < deadline) await sleep(50);
};
const log = (...args: unknown[]) => JSON_OUTPUT ? process.stderr.write(args.map(String).join(" ") + "\n") : console.log(...args);

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
    const summary = metrics.map((m) => `${kleur.dim(m.label + ":")} ${kleur.cyan(`${m.value.toFixed(m.unit === "%" ? 1 : 0)}${m.unit}`)}`).join("  ");
    log(`${kleur.green("PASS")}  ${kleur.dim(currentSuite)} / ${name}  ${kleur.dim(durationMs.toFixed(0) + "ms")}${summary ? "  " + summary : ""}`);
  } catch (e: any) {
    const durationMs = performance.now() - start;
    span.setStatus({ code: SpanStatusCode.ERROR, message: e?.message ?? String(e) });
    span.recordException(e);
    results.push({ suite: currentSuite, name, passed: false, durationMs, metrics: [], error: e?.message ?? String(e) });
    log(`${kleur.red("FAIL")}  ${kleur.dim(currentSuite)} / ${name}  ${kleur.dim(durationMs.toFixed(0) + "ms")}  ${kleur.red(e?.message ?? e)}`);
    if (e?.stack) log(kleur.dim(e.stack));
  } finally {
    span.end();
  }
}

function suite(name: string) {
  currentSuite = name;
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
      const msg = `Timed out waiting for ${label} (${latencyMs.toFixed(0)}ms)`;
      span.setStatus({ code: SpanStatusCode.ERROR, message: msg });
      span.end();
      throw new Error(msg);
    }
    span.setAttribute("latency_ms", latencyMs);
    span.setStatus({ code: SpanStatusCode.OK });
    span.end();
    return { value, latencyMs };
  });
}

async function stopClient(supabase: SupabaseClient) {
  await Promise.all([supabase.removeAllChannels(), supabase.auth.stopAutoRefresh()]);
  const { error } = await supabase.auth.signOut();
  if (error) log(kleur.dim(`stopClient signOut: ${error.message}`));
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
      const msg = `Channel failed to subscribe (topic: ${channel.topic}, state: ${channel.state}, elapsed: ${latencyMs.toFixed(0)}ms)`;
      span.setStatus({ code: SpanStatusCode.ERROR, message: msg });
      span.end();
      throw new Error(msg);
    }
    span.setAttribute("latency_ms", latencyMs);
    span.setStatus({ code: SpanStatusCode.OK });
    span.end();
    return latencyMs;
  });
}

// Subscribes a channel and waits until it is fully joined.
// All data operations must happen after this returns to avoid delivery races.
async function openChannel(channel: ReturnType<SupabaseClient["channel"]>): Promise<number> {
  channel.subscribe();
  return waitForSubscribed(channel);
}

// Subscribes a postgres_changes channel and waits for both the join and the
// system:ok confirmation that the server-side WAL subscription is active.
async function openPostgresChannel(channel: ReturnType<SupabaseClient["channel"]>): Promise<{ subscribeMs: number; systemMs: number }> {
  const start = performance.now();
  let systemOk = false;
  channel.on("system", "*", ({ status }: { status: string }) => { if (status === "ok") systemOk = true; });
  const subscribeMs = await openChannel(channel);
  const { latencyMs: systemMs } = await waitFor(() => systemOk ? true : null, "system ok");
  return { subscribeMs, systemMs: performance.now() - start };
}

// Channel config that opts in to the "Replication connection established" system
// message, used by broadcast-from-database tests to avoid sleeping while the
// tenant replication connection comes up.
const REPLICATION_READY_CONFIG = { config: { private: true, broadcast: { replication_ready: true } } } as any;

// Subscribes a private broadcast-from-database channel and waits for both the join
// and the server's replication-ready system message, so inserts that rely on the
// replication connection are not raced.
async function openReplicationChannel(channel: ReturnType<SupabaseClient["channel"]>): Promise<{ subscribeMs: number; replicationMs: number }> {
  const start = performance.now();
  let replicationReady = false;
  channel.on("system", "*", ({ extension, status }: { extension?: string; status?: string }) => {
    if (extension === "system" && status === "ok") replicationReady = true;
  });
  const subscribeMs = await openChannel(channel);
  await waitFor(() => replicationReady ? true : null, "replication ready");
  return { subscribeMs, replicationMs: performance.now() - start };
}

type TableName = "pg_changes" | "dummy" | "authorization" | "broadcast_changes" | "wallet" | "replay_check";

async function executeInsert(supabase: SupabaseClient, table: TableName, value?: string): Promise<number> {
  const { data, error } = await supabase.from(table).insert([{ value: value ?? crypto.randomUUID() }]).select("id");
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

async function setup(): Promise<{ userId: string; testUser: { email: string; password: string }; supabase: SupabaseClient }> {
  const start = performance.now();
  const email = `realtime-check-${crypto.randomUUID()}@${EMAIL_DOMAIN}`;
  const password = crypto.randomUUID();

  log("setup: connecting to database");
  const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
  let userId: string;
  try {
    let stepStart = performance.now();
    log(kleur.dim("setup: truncating existing tables"));
    await Promise.allSettled([
      sql`TRUNCATE TABLE public.pg_changes, public.dummy, public.authorization, public.broadcast_changes, public.replay_check`.then(
        () => log(kleur.dim("setup:   truncate ok")),
        (e: unknown) => log(kleur.dim(`setup:   truncate skipped (${e instanceof Error ? e.message : String(e)})`))
      ),
    ]);
    log(kleur.dim(`setup: truncate done (${(performance.now() - stepStart).toFixed(0)}ms)`));

    stepStart = performance.now();
    log(kleur.dim("setup: creating tables"));
    await Promise.allSettled([
      runSql("table pg_changes", sql`CREATE TABLE IF NOT EXISTS public.pg_changes (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid(),
            details text
          )`),
      runSql("table dummy", sql`CREATE TABLE IF NOT EXISTS public.dummy (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid()
          )`),
      runSql("table authorization", sql`CREATE TABLE IF NOT EXISTS public.authorization (
            id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            value text NOT NULL DEFAULT gen_random_uuid()
          )`),
      runSql("table broadcast_changes", sql`CREATE TABLE IF NOT EXISTS public.broadcast_changes (id text PRIMARY KEY, value text NOT NULL, topic text NOT NULL)`),
      runSql("table wallet", sql`CREATE TABLE IF NOT EXISTS public.wallet (id text PRIMARY KEY, wallet_id text NOT NULL)`),
      runSql("table replay_check", sql`CREATE TABLE IF NOT EXISTS public.replay_check (
            id text PRIMARY KEY,
            topic text NOT NULL,
            event text NOT NULL,
            payload jsonb NOT NULL DEFAULT '{}'
          )`),
    ]);
    await runSql("pg_changes details column", sql`ALTER TABLE public.pg_changes ADD COLUMN IF NOT EXISTS details text`);
    await runSql("pg_changes nullable_value column", sql`ALTER TABLE public.pg_changes ADD COLUMN IF NOT EXISTS nullable_value text`);
    await runSql("pg_changes replica identity", sql`ALTER TABLE public.pg_changes REPLICA IDENTITY FULL`);
    log(kleur.dim(`setup: tables done (${(performance.now() - stepStart).toFixed(0)}ms)`));

    stepStart = performance.now();
    log(kleur.dim("setup: configuring RLS and publications"));
    await Promise.allSettled([
      runSql("wallet seed", sql`INSERT INTO public.wallet (id, wallet_id) VALUES ('1', 'wallet_1') ON CONFLICT (id) DO NOTHING`),
      runSql("dummy RLS disable", sql`ALTER TABLE public.dummy DISABLE ROW LEVEL SECURITY`),
      runSql("pg_changes RLS enable", sql`ALTER TABLE public.pg_changes ENABLE ROW LEVEL SECURITY`),
      runSql("authorization RLS enable", sql`ALTER TABLE public.authorization ENABLE ROW LEVEL SECURITY`),
      runSql("broadcast_changes RLS enable", sql`ALTER TABLE public.broadcast_changes ENABLE ROW LEVEL SECURITY`),
      runSql("wallet RLS enable", sql`ALTER TABLE public.wallet ENABLE ROW LEVEL SECURITY`),
      runSql("replay_check RLS enable", sql`ALTER TABLE public.replay_check ENABLE ROW LEVEL SECURITY`),
      sql`ALTER PUBLICATION supabase_realtime ADD TABLE public.pg_changes`
        .then((r) => log(kleur.dim(`setup:   publication pg_changes ok (${fmtSqlResult(r)})`)))
        .catch((e: unknown) => log(kleur.dim(`setup:   publication pg_changes skipped (${e instanceof Error ? e.message : String(e)})`))),
      sql`ALTER PUBLICATION supabase_realtime ADD TABLE public.dummy`
        .then((r) => log(kleur.dim(`setup:   publication dummy ok (${fmtSqlResult(r)})`)))
        .catch((e: unknown) => log(kleur.dim(`setup:   publication dummy skipped (${e instanceof Error ? e.message : String(e)})`))),
    ]);
    log(kleur.dim(`setup: RLS and publications done (${(performance.now() - stepStart).toFixed(0)}ms)`));

    stepStart = performance.now();
    log(kleur.dim("setup: creating policies"));
    await Promise.allSettled([
      runSql("policy 'authenticated receive on topic'", sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated receive on topic' AND tablename = 'messages' AND schemaname = 'realtime') THEN
              CREATE POLICY "authenticated receive on topic" ON "realtime"."messages" AS PERMISSIVE
                FOR SELECT TO authenticated USING (realtime.topic() like 'topic:%');
            END IF;
          END $$`),
      runSql("policy 'authenticated broadcast on topic'", sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated broadcast on topic' AND tablename = 'messages' AND schemaname = 'realtime') THEN
              CREATE POLICY "authenticated broadcast on topic" ON "realtime"."messages" AS PERMISSIVE
                FOR INSERT TO authenticated WITH CHECK (realtime.topic() like 'topic:%');
            END IF;
          END $$`),
      runSql("policy 'allow authenticated users all access'", sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'allow authenticated users all access' AND tablename = 'pg_changes' AND schemaname = 'public') THEN
              CREATE POLICY "allow authenticated users all access" ON "public"."pg_changes" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE);
            END IF;
          END $$`),
      runSql("policy 'authenticated have full access to read on broadcast_changes'", sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated have full access to read on broadcast_changes' AND tablename = 'broadcast_changes' AND schemaname = 'public') THEN
              CREATE POLICY "authenticated have full access to read on broadcast_changes" ON "public"."broadcast_changes" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE);
            END IF;
          END $$`),
      runSql("policy 'authenticated have full access to replay_check'", sql`DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'authenticated have full access to replay_check' AND tablename = 'replay_check' AND schemaname = 'public') THEN
              CREATE POLICY "authenticated have full access to replay_check" ON "public"."replay_check" AS PERMISSIVE
                FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);
            END IF;
          END $$`),
    ]);
    log(kleur.dim(`setup: policies done (${(performance.now() - stepStart).toFixed(0)}ms)`));

    stepStart = performance.now();
    log(kleur.dim("setup: creating functions and triggers"));
    await runSql("function broadcast_changes_for_table_trigger", sql`
      CREATE OR REPLACE FUNCTION broadcast_changes_for_table_trigger() RETURNS TRIGGER AS $$
      DECLARE topic text;
      BEGIN
        topic = COALESCE(NEW.topic, OLD.topic);
        PERFORM realtime.broadcast_changes(topic, TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD, TG_LEVEL);
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
    `);
    await runSql("broadcast_changes topic column", sql`ALTER TABLE public.broadcast_changes ADD COLUMN IF NOT EXISTS topic text NOT NULL`);

    await runSql("trigger broadcast_changes_for_table_public_broadcast_changes_trigger", sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'broadcast_changes_for_table_public_broadcast_changes_trigger') THEN
          CREATE TRIGGER broadcast_changes_for_table_public_broadcast_changes_trigger
            AFTER INSERT OR UPDATE OR DELETE ON broadcast_changes
            FOR EACH ROW EXECUTE FUNCTION broadcast_changes_for_table_trigger();
        END IF;
      END $$
    `);

    await runSql("function replay_check_trigger", sql`
      CREATE OR REPLACE FUNCTION replay_check_trigger() RETURNS TRIGGER AS $$
      BEGIN
        PERFORM realtime.send(NEW.payload, NEW.event, NEW.topic, true);
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
    `);

    await runSql("trigger replay_check_send_trigger", sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'replay_check_send_trigger') THEN
          CREATE TRIGGER replay_check_send_trigger
            AFTER INSERT ON public.replay_check
            FOR EACH ROW EXECUTE FUNCTION replay_check_trigger();
        END IF;
      END $$
    `);

    log(kleur.dim(`setup: functions and triggers done (${(performance.now() - stepStart).toFixed(0)}ms)`));

    log(kleur.dim("setup: creating test user"));
    const admin = createClient(PROJECT_URL, SERVICE_KEY);
    const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (error) throw new Error(`Failed to create test user: ${error.message}`);
    userId = data.user.id;
    log(kleur.dim(`setup: done (${(performance.now() - start).toFixed(0)}ms)`));
  } finally {
    await sql.close().catch(() => {});
  }

  const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
  await signInUser(supabase, email, password);
  return { userId: userId!, testUser: { email, password }, supabase };
}

async function cleanup(userId: string) {
  log("cleanup: deleting test user");
  const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
  try {
    await sql`DELETE FROM auth.users WHERE id = ${userId}`;
    log(kleur.dim("cleanup: done"));
  } catch (_e) {
    log(kleur.yellow("Warning: failed to clean up test user"));
  } finally {
    await sql.close().catch(() => {});
  }
}

async function runConnectionTest() {
  suite("connection");

  await test("first connect latency", async () => {
    const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
    try {
      const channel = supabase.channel(randomTopic());
      const connectMs = await openChannel(channel);
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
      const topic = randomTopic();
      const event = "load";
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openChannel(channel);

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
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes" }, () => {});
      const { systemMs } = await openPostgresChannel(channel);
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
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.new.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openPostgresChannel(channel);

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
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.new.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openPostgresChannel(channel);

      const ids = await Promise.all(Array.from({ length: LOAD_MESSAGES }, () => executeInsert(supabase, "pg_changes")));

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
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "pg_changes" }, (p) => {
          const t = sendTimes.get(p.old.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openPostgresChannel(channel);

      const ids = await Promise.all(Array.from({ length: LOAD_MESSAGES }, () => executeInsert(supabase, "pg_changes")));

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
      const topic = randomTopic();
      const trackTimes = new Map<string, number>();
      const latencies: number[] = [];

      const observerChannel = observer
        .channel(topic, { config: { broadcast: { self: true }, presence: { key: "observer" } } })
        .on("presence", { event: "join" }, (e) => {
          if (e.key === "observer") return;
          const t = trackTimes.get(e.key);
          if (t !== undefined) latencies.push(performance.now() - t);
        });
      await openChannel(observerChannel);

      const clients = Array.from({ length: CLIENTS }, (_, i) => ({
        client: createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS }),
        key: `client-${i}`,
      }));
      senders.push(...clients.map((c) => c.client));

      const channels = await Promise.all(clients.map(async ({ client, key }) => {
        const ch = client.channel(topic, { config: { presence: { key } } });
        await openChannel(ch);
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
      const testTopic = randomTopic();
      const sendTimes = new Map<string, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(testTopic, { config: { private: true } })
        .on("broadcast", { event: "INSERT" }, (res) => {
          const t = sendTimes.get(res.payload.record.id);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openChannel(channel);

      await Promise.all(Array.from({ length: LOAD_MESSAGES }, async () => {
        const id = crypto.randomUUID();
        sendTimes.set(id, performance.now());
        await supabase.from("broadcast_changes").insert({ id, value: crypto.randomUUID(), topic: testTopic });
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
      const topic = randomTopic();
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openChannel(channel);

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
      const topic = randomTopic();
      const sendTimes = new Map<number, number>();
      const latencies: number[] = [];

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => {
          const t = sendTimes.get(payload.seq);
          if (t !== undefined) latencies.push(performance.now() - t);
        });

      await openChannel(channel);

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
      const topic = randomTopic();

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
      });
      await openChannel(receiver);

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
      const topic = randomTopic();
      const expectedPayload = { message: crypto.randomUUID() };

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => (result = payload));

      const subscribeMs = await openChannel(channel);
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
      const topic = randomTopic();
      const expectedPayload = { message: crypto.randomUUID() };

      const channel = supabase
        .channel(topic, BROADCAST_CONFIG)
        .on("broadcast", { event }, ({ payload }) => (result = payload));

      const subscribeMs = await openChannel(channel);
      // Small settle window so server-side subscription routing is ready before the HTTP broadcast arrives.
      await sleep(100);

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

async function runPresenceTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("presence extension");

  await test("user is able to receive presence updates", async () => {
    try {
      let joinEvent: any = null;
      const topic = randomTopic();
      const message = crypto.randomUUID();
      const key = crypto.randomUUID();

      const channel = supabase
        .channel(topic, { config: { broadcast: { self: true }, presence: { key } } })
        .on("presence", { event: "join" }, (e) => (joinEvent = e));

      const subscribeMs = await openChannel(channel);
      const trackStart = performance.now();
      if (await channel.track({ message }) === "timed out") throw new Error("track() timed out");
      const trackMs = performance.now() - trackStart;
      const { latencyMs: eventMs } = await waitFor(() => joinEvent, "presence join");

      assert.strictEqual(joinEvent.key, key);
      assert.strictEqual(joinEvent.newPresences[0].message, message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "track", value: trackMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user is able to receive presence updates on private channels", async () => {
    try {

      let joinEvent: any = null;
      const topic = randomTopic();
      const message = crypto.randomUUID();
      const key = crypto.randomUUID();

      const channel = supabase
        .channel(topic, { config: { private: true, broadcast: { self: true }, presence: { key } } })
        .on("presence", { event: "join" }, (e) => (joinEvent = e));

      const subscribeMs = await openChannel(channel);
      const trackStart = performance.now();
      if (await channel.track({ message }) === "timed out") throw new Error("track() timed out");
      const trackMs = performance.now() - trackStart;
      const { latencyMs: eventMs } = await waitFor(() => joinEvent, "presence join");

      assert.strictEqual(joinEvent.key, key);
      assert.strictEqual(joinEvent.newPresences[0].message, message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "track", value: trackMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });
}

async function runAuthorizationTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("authorization check");

  await test("user using private channel cannot connect without permissions", async () => {
    try {
      const topic = "restricted:" + crypto.randomUUID();
      const channel = supabase.channel(topic, { config: { private: true } }).subscribe();

      const { value: finalState, latencyMs: rejectMs } = await waitFor(
        () => channel.state !== "joining" ? channel.state : null,
        "channel rejection"
      );

      assert.notStrictEqual(finalState, "joined", `Expected channel to be rejected but state is: ${finalState}`);
      return [{ label: "rejection", value: rejectMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user using private channel can connect with enough permissions", async () => {
    try {
      const channel = supabase.channel(randomTopic(), { config: { private: true } });
      const subscribeMs = await openChannel(channel);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });
}

async function runBroadcastChangesTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("broadcast changes");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives INSERT broadcast change", async () => {
    try {
      const testTopic = randomTopic();
      const id = crypto.randomUUID();
      const value = crypto.randomUUID();
      let result: any = null;

      const channel = supabase
        .channel(testTopic, REPLICATION_READY_CONFIG)
        .on("broadcast", { event: "INSERT" }, (res) => (result = res));

      const { subscribeMs } = await openReplicationChannel(channel);
      await supabase.from("broadcast_changes").insert({ value, id, topic: testTopic });
      const { latencyMs: eventMs } = await waitFor(() => result, "INSERT event");

      assert.strictEqual(result.payload.record.id, id);
      assert.strictEqual(result.payload.record.value, value);
      assert.strictEqual(result.payload.old_record, null);
      assert.strictEqual(result.payload.operation, "INSERT");
      assert.strictEqual(result.payload.schema, "public");
      assert.strictEqual(result.payload.table, "broadcast_changes");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives UPDATE broadcast change", async () => {
    try {
      const testTopic = randomTopic();
      const id = crypto.randomUUID();
      const originalValue = crypto.randomUUID();
      const updatedValue = crypto.randomUUID();
      let result: any = null;

      const channel = supabase
        .channel(testTopic, REPLICATION_READY_CONFIG)
        .on("broadcast", { event: "UPDATE" }, (res) => (result = res));

      const { subscribeMs } = await openReplicationChannel(channel);
      await supabase.from("broadcast_changes").insert({ value: originalValue, id, topic: testTopic });
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
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("authenticated user receives DELETE broadcast change", async () => {
    try {
      const testTopic = randomTopic();
      const id = crypto.randomUUID();
      const value = crypto.randomUUID();
      let result: any = null;

      const channel = supabase
        .channel(testTopic, REPLICATION_READY_CONFIG)
        .on("broadcast", { event: "DELETE" }, (res) => (result = res));

      const { subscribeMs } = await openReplicationChannel(channel);
      await supabase.from("broadcast_changes").insert({ value, id, topic: testTopic });
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
      await supabase.removeAllChannels();
    }
  });
}

async function runPostgresChangesTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("postgres changes extension");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives INSERT events with filter", async () => {
    try {

      let result: unknown = null;
      const uniqueValue = crypto.randomUUID();

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "INSERT", schema: "public", table: "pg_changes", filter: `value=eq.${uniqueValue}` },
          (payload) => (result = payload));

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", uniqueValue);
      await executeInsert(supabase, "dummy");
      const { latencyMs: eventMs } = await waitFor(() => result, "INSERT event");

      assert.strictEqual(result.eventType, "INSERT");
      assert.strictEqual(result.new.value, uniqueValue);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives UPDATE events with filter", async () => {
    try {

      let result: unknown = null;
      const mainId = await executeInsert(supabase, "pg_changes");
      const fakeId = await executeInsert(supabase, "pg_changes");
      const dummyId = await executeInsert(supabase, "dummy");

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "UPDATE", schema: "public", table: "pg_changes", filter: `id=eq.${mainId}` },
          (payload) => (result = payload));

      const { subscribeMs } = await openPostgresChannel(channel);
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
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives DELETE events with filter", async () => {
    try {

      let result: unknown = null;
      const mainId = await executeInsert(supabase, "pg_changes");
      const fakeId = await executeInsert(supabase, "pg_changes");
      const dummyId = await executeInsert(supabase, "dummy");

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "DELETE", schema: "public", table: "pg_changes", filter: `id=eq.${mainId}` },
          (payload) => (result = payload));

      const { subscribeMs } = await openPostgresChannel(channel);
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
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("user receives INSERT, UPDATE and DELETE concurrently", async () => {
    try {
      let insertResult: unknown = null, updateResult: unknown = null, deleteResult: unknown = null;

      const insertValue = crypto.randomUUID();
      const updateId = await executeInsert(supabase, "pg_changes");
      const deleteId = await executeInsert(supabase, "pg_changes");

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: `value=eq.${insertValue}` }, (p) => (insertResult = p))
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "pg_changes", filter: `id=eq.${updateId}` }, (p) => (updateResult = p))
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "pg_changes", filter: `id=eq.${deleteId}` }, (p) => (deleteResult = p));

      const { subscribeMs } = await openPostgresChannel(channel);

      await Promise.all([
        executeInsert(supabase, "pg_changes", insertValue),
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
      await supabase.removeAllChannels();
    }
  });

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("select — omitting select returns full payload (backward compatible)", async () => {
    try {
      let result: any = null;
      const uniqueValue = crypto.randomUUID();
      const details = crypto.randomUUID();

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes",
          { event: "INSERT", schema: "public", table: "pg_changes", filter: `value=eq.${uniqueValue}` },
          (payload) => (result = payload));

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert({ value: uniqueValue, details });
      const { latencyMs: eventMs } = await waitFor(() => result, "INSERT event");

      assert.strictEqual(result.eventType, "INSERT");
      assert.ok(result.new.id !== undefined, "id must be present");
      assert.strictEqual(result.new.value, uniqueValue, "value must be present when no select is used");
      assert.strictEqual(result.new.details, details, "details must be present when no select is used");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

}

async function runPostgresChangesFiltersTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("postgres-changes-filters");

  await test("eq: delivers row equal to the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `eq_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("value", value) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "eq event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("neq: delivers row not equal to the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `neq_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().neq("value", `no_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "neq event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("lt: delivers row less than the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `a_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().lt("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "lt event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("lte: delivers row less than or equal to the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `a_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().lte("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "lte event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("gt: delivers row greater than the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `c_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().gt("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "gt event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("gte: delivers row greater than or equal to the value", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `c_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().gte("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "gte event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("in: delivers row whose value is in the list", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `in_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().in("value", [value, `other_${tag}`]) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "in event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("like: delivers row matching the pattern", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `${tag}hello`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().like("value", `${tag}%`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "like event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("ilike: matches the pattern case-insensitively", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `${tag}HELLO`; // upper-cased value, lower-cased filter
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().ilike("value", `${tag}hello%`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "ilike event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });


  await test("is: delivers row whose nullable column is null", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `is_${tag}`; // executeInsert only sets `value`, so nullable_value stays null
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().is("nullable_value", null) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "is event");

      assert.strictEqual(result.new.nullable_value, null);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("match: delivers row matching the regex", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `${tag}abc123`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().match("value", `^${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "match event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("imatch: matches the regex case-insensitively", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `${tag}ABC`; // upper-cased value, lower-cased regex
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().imatch("value", `^${tag}abc`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "imatch event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("isdistinct: delivers row whose value is distinct from the literal", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `isd_${tag}`;
      let result: any = null;

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().isDistinct("value", `other_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", value);
      await waitFor(() => result, "isdistinct event");

      assert.strictEqual(result.new.value, value);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("and: delivers only rows matching every comma-separated condition", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}both`;
      const decoy = `${tag}one`;
      const seen: string[] = [];

      // value LIKE tag%  AND  details = tag-keep
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().like("value", `${tag}%`).eq("details", `${tag}keep`) }, (p) => { seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match, details: `${tag}keep` }, // satisfies both conditions
        { value: decoy, details: `${tag}nope` }, // satisfies only the value condition
      ]);
      await waitFor(() => (seen.includes(match) ? true : null), "and event");
      await sleep(1000); // give the decoy a chance to arrive if AND were wrongly treated as OR

      assert.ok(seen.includes(match), "row matching both conditions must be delivered");
      assert.ok(!seen.includes(decoy), "row matching only one condition must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("not: excludes the negated value and delivers the rest", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const excluded = `${tag}skip`;
      const delivered = `${tag}keep`;
      const seen: string[] = [];

      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().not("value", "eq", excluded) }, (p) => { if (p.new.value === excluded || p.new.value === delivered) seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await executeInsert(supabase, "pg_changes", excluded);
      await executeInsert(supabase, "pg_changes", delivered);
      await waitFor(() => (seen.includes(delivered) ? true : null), "not event");
      await sleep(1000); // give the excluded row a chance to arrive if the negation were ignored

      assert.ok(seen.includes(delivered), "non-matching row must be delivered");
      assert.ok(!seen.includes(excluded), "negated value must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: combines and, not and a pattern filter", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}ok`;
      const decoy = `${tag}ok2`;
      const seen: string[] = [];

      // value LIKE tag%  AND  details NOT LIKE skip%  AND  nullable_value IS NULL
      const filter = postgresChangesFilter().like("value", `${tag}%`).not("details", "like", "skip%").is("nullable_value", null);
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match, details: "keep" }, // matches all three (nullable_value defaults to null)
        { value: decoy, details: "skipme" }, // fails details NOT LIKE skip%
      ]);
      await waitFor(() => (seen.includes(match) ? true : null), "compose event");
      await sleep(1000);

      assert.ok(seen.includes(match), "row matching all three conditions must be delivered");
      assert.ok(!seen.includes(decoy), "row failing the not.like condition must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: bounded range with gte and lte on the same column", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}_c`; // inside [b, d]
      const tooLow = `${tag}_a`; // below the lower bound
      const tooHigh = `${tag}_e`; // above the upper bound
      const seen: string[] = [];

      // value >= tag_b  AND  value <= tag_d
      const filter = postgresChangesFilter().gte("value", `${tag}_b`).lte("value", `${tag}_d`);
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match },
        { value: tooLow },
        { value: tooHigh },
      ]);
      await waitFor(() => (seen.includes(match) ? true : null), "range event");
      await sleep(1000); // give the out-of-range rows a chance to arrive if a bound were ignored

      assert.ok(seen.includes(match), "in-range row must be delivered");
      assert.ok(!seen.includes(tooLow), "row below the lower bound must be excluded");
      assert.ok(!seen.includes(tooHigh), "row above the upper bound must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: combines in list with a like pattern across columns", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `in_${tag}`;
      const decoy = `in_${tag}`; // same value, but details fail the like condition
      const seen: string[] = [];

      // value IN (in_tag, other_tag)  AND  details LIKE keep%
      const filter = postgresChangesFilter().in("value", [match, `other_${tag}`]).like("details", "keep%");
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value === match) seen.push(p.new.details); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match, details: `keep_${tag}` }, // satisfies both conditions
        { value: decoy, details: `drop_${tag}` }, // in the list but details fail the like
      ]);
      await waitFor(() => (seen.includes(`keep_${tag}`) ? true : null), "in+like event");
      await sleep(1000);

      assert.ok(seen.includes(`keep_${tag}`), "row matching both the in list and the like pattern must be delivered");
      assert.ok(!seen.includes(`drop_${tag}`), "row failing the like pattern must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: combines neq with not.like", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}keep`;
      const decoyEq = `${tag}exact`; // fails the neq
      const decoyLike = `${tag}skipme`; // fails the not.like
      const seen: string[] = [];

      // value != tag-exact  AND  value NOT LIKE tag-skip%
      const filter = postgresChangesFilter().neq("value", `${tag}exact`).not("value", "like", `${tag}skip%`);
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match },
        { value: decoyEq },
        { value: decoyLike },
      ]);
      await waitFor(() => (seen.includes(match) ? true : null), "neq+not.like event");
      await sleep(1000);

      assert.ok(seen.includes(match), "row satisfying both negations must be delivered");
      assert.ok(!seen.includes(decoyEq), "row equal to the excluded value must be excluded");
      assert.ok(!seen.includes(decoyLike), "row matching the excluded pattern must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: combines is.not.null with an ilike pattern", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}HELLO`;
      const decoyNull = `${tag}HELLO2`; // fails is.not.null (nullable_value stays null)
      const decoyLike = `${tag}WORLD`; // fails the ilike pattern
      const seen: string[] = [];

      // nullable_value IS NOT NULL  AND  value ILIKE tag-hello%
      const filter = postgresChangesFilter().not("nullable_value", "is", null).ilike("value", `${tag}hello%`);
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match, nullable_value: `set_${tag}` }, // satisfies both conditions
        { value: decoyNull }, // nullable_value is null
        { value: decoyLike, nullable_value: `set_${tag}` }, // fails the ilike
      ]);
      await waitFor(() => (seen.includes(match) ? true : null), "is.not.null+ilike event");
      await sleep(1000);

      assert.ok(seen.includes(match), "row with a non-null column matching the pattern must be delivered");
      assert.ok(!seen.includes(decoyNull), "row with a null column must be excluded");
      assert.ok(!seen.includes(decoyLike), "row failing the ilike pattern must be excluded");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("compose: four conditions across three columns", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const match = `${tag}match`;
      const decoyValue = `${tag}other`; // fails value=eq
      const decoyDetails = `${tag}match`; // details fail the not.like
      const decoyNull = `${tag}match`; // nullable_value is null
      const seen: Array<{ value: string; details: string }> = [];

      // value = tag-match  AND  details NOT LIKE skip%  AND  details LIKE keep%  AND  nullable_value IS NOT NULL
      const filter = postgresChangesFilter().eq("value", match).not("details", "like", "skip%").like("details", "keep%").not("nullable_value", "is", null);
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push({ value: p.new.value, details: p.new.details }); });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([
        { value: match, details: "keep_a", nullable_value: `set_${tag}` }, // satisfies all four
        { value: decoyValue, details: "keep_b", nullable_value: `set_${tag}` }, // wrong value
        { value: decoyDetails, details: "skip_c", nullable_value: `set_${tag}` }, // details start with skip
        { value: decoyNull, details: "keep_d" }, // nullable_value is null
      ]);
      await waitFor(() => (seen.some((r) => r.details === "keep_a") ? true : null), "four-condition event");
      await sleep(1000);

      assert.strictEqual(seen.length, 1, "exactly one row must satisfy all four conditions");
      assert.strictEqual(seen[0].details, "keep_a");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("select: restricts the payload to the chosen columns", async () => {
    try {
      const tag = crypto.randomUUID().replace(/-/g, "");
      const value = `select_${tag}`;
      let result: any = null;

      // Ask for only id + value; details and nullable_value must be absent from the payload.
      const channel = supabase
        .channel(randomTopic(), BROADCAST_CONFIG)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("value", value), select: ["id", "value"] }, (p) => { if (p.new.value === value) result = p; });

      const { subscribeMs } = await openPostgresChannel(channel);
      await supabase.from("pg_changes").insert([{ value, details: `${tag}details`, nullable_value: `${tag}nv` }]);
      await waitFor(() => result, "select event");

      assert.strictEqual(result.new.value, value);
      assert.deepStrictEqual(Object.keys(result.new).sort(), ["id", "value"], "payload must only contain the selected columns");
      assert.ok(!("details" in result.new), "unselected details column must be absent");
      assert.ok(!("nullable_value" in result.new), "unselected nullable_value column must be absent");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

}

async function runBroadcastReplayTests(_testUser: { email: string; password: string }, supabase: SupabaseClient) {
  suite("broadcast replay");

  await test("replayed messages are delivered on join", async () => {
    try {
      const event = crypto.randomUUID();
      const topic = randomTopic();
      const payload = { message: crypto.randomUUID() };

      const since = Date.now() - 1000;
      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload });

      await sleep(500);

      let result: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 1 } } },
      }).on("broadcast", { event }, (msg) => (result = msg.payload));
      const subscribeMs = await openChannel(receiver);

      const { latencyMs: replayMs } = await waitFor(() => result, "replayed broadcast event");

      assert.strictEqual(result.message, payload.message);
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "replay", value: replayMs, unit: "ms" }];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("replayed messages carry meta.replayed flag", async () => {
    try {
      const event = crypto.randomUUID();
      const topic = randomTopic();

      const since = Date.now() - 1000;
      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { value: 1 } });

      await sleep(500);

      let receivedMeta: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 1 } } },
      }).on("broadcast", { event }, (msg) => (receivedMeta = msg.meta));
      await openChannel(receiver);

      await waitFor(() => receivedMeta, "replayed broadcast meta");

      assert.strictEqual(receivedMeta?.replayed, true);
      return [];
    } finally {
      await supabase.removeAllChannels();
    }
  });

  await test("messages before since are not replayed", async () => {
    try {
      const event = crypto.randomUUID();
      const topic = randomTopic();

      await supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { value: "old" } });

      // Sleep to ensure the DB insert timestamp is clearly before `since`,
      // guarding against clock skew between JS client and DB server.
      await sleep(1000);
      const since = Date.now();

      let result: any = null;
      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 25 } } },
      }).on("broadcast", { event }, (msg) => (result = msg.payload));
      await openChannel(receiver);

      await sleep(500);

      assert.strictEqual(result, null);
      return [];
    } finally {
      await supabase.removeAllChannels();
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

  log(`\n${kleur.bold(`${passed.length} passed, ${failed.length} failed`)}  ${kleur.dim(`total ${(totalMs / 1000).toFixed(2)}s`)}`);

  if (failed.length > 0) {
    log("\nFailed:");
    for (const r of failed) {
      log(`  ${kleur.red("✗")} ${r.suite} / ${r.name}`);
      if (r.error) log(`    ${kleur.dim(r.error)}`);
    }
  }
}

type SuiteCtx = { testUser: { email: string; password: string }; supabase: SupabaseClient };

const SUITES: Record<string, (ctx: SuiteCtx) => Promise<void>> = {
  "connection": () => runConnectionTest(),
  "load-postgres-changes": ({ testUser }) => runLoadPostgresChangesTests(testUser),
  "load-presence": () => runLoadPresenceTests(),
  "load-broadcast": () => runLoadBroadcastTests(),
  "load-broadcast-from-db": ({ testUser }) => runLoadBroadcastFromDbTests(testUser),
  "load-broadcast-replay": ({ testUser }) => runLoadBroadcastReplayTests(testUser),
  "broadcast": () => runBroadcastTests(),
  "broadcast-replay": ({ testUser, supabase }) => runBroadcastReplayTests(testUser, supabase),
  "presence": ({ testUser, supabase }) => runPresenceTests(testUser, supabase),
  "authorization": ({ testUser, supabase }) => runAuthorizationTests(testUser, supabase),
  "postgres-changes": ({ testUser, supabase }) => runPostgresChangesTests(testUser, supabase),
  "postgres-changes-filters": ({ testUser, supabase }) => runPostgresChangesFiltersTests(testUser, supabase),
  "broadcast-changes": ({ testUser, supabase }) => runBroadcastChangesTests(testUser, supabase),
  "broadcast-binary": ({ supabase }) => runBroadcastBinaryTests(supabase),
};

async function runBroadcastBinaryTests(supabase: SupabaseClient) {
  suite("broadcast binary");

  await sleep(RATE_LIMIT_PAUSE_MS);
  await test("send_binary delivers a binary broadcast", async () => {
    const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
    try {
      const event = crypto.randomUUID();
      const topic = randomTopic();
      const binary = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff]);

      let result: any = null;
      const channel = supabase
        .channel(topic, REPLICATION_READY_CONFIG)
        .on("broadcast", { event }, (msg) => (result = msg.payload));

      const { subscribeMs } = await openReplicationChannel(channel);

      await sql`SELECT realtime.send_binary(${binary}::bytea, ${event}::text, ${topic}::text, true)`;

      const { latencyMs: eventMs } = await waitFor(() => result, "binary broadcast event");

      const received = result instanceof Uint8Array ? result : new Uint8Array(result);
      assert.strictEqual(received.length, binary.length, "binary payload length mismatch");
      assert.ok(binary.every((b, i) => received[i] === b), "binary payload bytes mismatch");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
    } finally {
      await sql.close().catch(() => {});
      await supabase.removeAllChannels();
    }
  });
}

const LOAD_SUITES = Object.keys(SUITES).filter((k) => k.startsWith("load"));
const FUNCTIONAL_SUITES = Object.keys(SUITES).filter((k) => !k.startsWith("load"));

const DB_REQUIRED_SUITES = new Set([
  "load-postgres-changes",
  "load-broadcast-from-db",
  "load-broadcast-replay",
  "broadcast-replay",
  "presence",
  "authorization",
  "postgres-changes",
  "postgres-changes-filters",
  "broadcast-changes",
  "broadcast-binary",
]);

async function main() {
  initOtel();
  patchFetch();

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
  }

  const suitesToRun = activeCategories
    ? Object.entries(SUITES).filter(([key]) => activeCategories.includes(key))
    : Object.entries(SUITES);

  const needsDb = suitesToRun.some(([key]) => DB_REQUIRED_SUITES.has(key));

  if (needsDb && !SERVICE_KEY) {
    console.error("--secret-key is required");
    process.exit(1);
  }

  if (needsDb && env !== "local" && !dbPassword && !DB_URL_ARG) {
    console.error("--db-password is required for staging and prod environments");
    process.exit(1);
  }

  let userId: string | null = null;
  let testUser: { email: string; password: string } = { email: "", password: "" };
  let supabase: SupabaseClient = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });

  if (needsDb) {
    const setupResult = await setup();
    userId = setupResult.userId;
    testUser = setupResult.testUser;
    supabase = setupResult.supabase;
  }

  const start = performance.now();
  try {
    for (const [, fn] of suitesToRun) await fn({ testUser, supabase });
  } finally {
    await stopClient(supabase);
    if (userId) await cleanup(userId);
  }

  printSummary(performance.now() - start);
  await flushOtel();

  if (results.some((r) => !r.passed)) process.exit(1);
}

main().catch((e) => {
  console.error(kleur.red("Fatal error:"), e.message);
  if (e?.stack) console.error(kleur.dim(e.stack));
  process.exit(1);
});
