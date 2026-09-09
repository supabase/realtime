import type { SupabaseClient } from "@supabase/supabase-js";
import kleur from "kleur";
import { trace, context, SpanStatusCode, SpanKind, ROOT_CONTEXT } from "@opentelemetry/api";
import { BasicTracerProvider, BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";
import { JSON_OUTPUT, OTEL_ENDPOINT, OTEL_API_TOKEN, PROJECT_URL, env } from "./context.ts";

export let tracer = trace.getTracer("realtime-check");
let otelProvider: BasicTracerProvider | null = null;

export function initOtel() {
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

export async function flushOtel() {
  if (otelProvider) await otelProvider.forceFlush();
}

export function patchFetch() {
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

export const log = (...args: unknown[]) => JSON_OUTPUT ? process.stderr.write(args.map(String).join(" ") + "\n") : console.log(...args);

export type Metric = { label: string; value: number; unit: string };
export type TestResult = { suite: string; name: string; passed: boolean; durationMs: number; metrics: Metric[]; error?: string };

export type SuiteCtx = {
  testUser: { email: string; password: string };
  supabase: SupabaseClient;
  test: (name: string, fn: () => Promise<Metric[]>) => Promise<void>;
};

export type SuiteDescriptor = {
  name: string;
  // Display label recorded against each TestResult (what suite() used to be called with) —
  // kept distinct from `name` because several suites' existing display labels
  // (e.g. "broadcast extension", "authorization check") differ from their --test category key.
  label: string;
  needsDb: boolean;
  run: (ctx: SuiteCtx) => Promise<void>;
};

export const results: TestResult[] = [];

// Suite-bound test() closure: labels results by `suiteName` directly instead of a shared
// mutable global, so suites stay correctly attributed even if run concurrently in the future.
export function createSuiteTest(suiteName: string) {
  return (name: string, fn: () => Promise<Metric[]>) => runTest(suiteName, name, fn);
}

async function runTest(suiteName: string, name: string, fn: () => Promise<Metric[]>) {
  const start = performance.now();
  const span = tracer.startSpan(name, {
    kind: SpanKind.INTERNAL,
    attributes: { "suite": suiteName, "env": env, "project.url": PROJECT_URL },
  });
  const testContext = trace.setSpan(ROOT_CONTEXT, span);
  try {
    const metrics = await context.with(testContext, fn);
    const durationMs = performance.now() - start;
    for (const m of metrics) span.setAttribute(`metric.${m.label}`, `${m.value.toFixed(2)}${m.unit}`);
    span.setStatus({ code: SpanStatusCode.OK });
    results.push({ suite: suiteName, name, passed: true, durationMs, metrics });
    const summary = metrics.map((m) => `${kleur.dim(m.label + ":")} ${kleur.cyan(`${m.value.toFixed(m.unit === "%" ? 1 : 0)}${m.unit}`)}`).join("  ");
    log(`${kleur.green("PASS")}  ${kleur.dim(suiteName)} / ${name}  ${kleur.dim(durationMs.toFixed(0) + "ms")}${summary ? "  " + summary : ""}`);
  } catch (e: any) {
    const durationMs = performance.now() - start;
    span.setStatus({ code: SpanStatusCode.ERROR, message: e?.message ?? String(e) });
    span.recordException(e);
    results.push({ suite: suiteName, name, passed: false, durationMs, metrics: [], error: e?.message ?? String(e) });
    log(`${kleur.red("FAIL")}  ${kleur.dim(suiteName)} / ${name}  ${kleur.dim(durationMs.toFixed(0) + "ms")}  ${kleur.red(e?.message ?? e)}`);
    if (e?.stack) log(kleur.dim(e.stack));
  } finally {
    span.end();
  }
}

export function printSummary(totalMs: number) {
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
