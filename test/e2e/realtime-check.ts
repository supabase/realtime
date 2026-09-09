#!/usr/bin/env bun
import assert from "assert";
import { createClient, SupabaseClient, postgresChangesFilter } from "@supabase/supabase-js";
import kleur from "kleur";
import { SQL } from "bun";
import {
  ANON_KEY, SERVICE_KEY, dbPassword, JSON_OUTPUT, DB_URL_ARG, env,
  TEST_CATEGORIES, PROJECT_URL, DB_URL, DB_SSL, REALTIME_OPTS, BROADCAST_CONFIG, EVENT_TIMEOUT_MS,
  RATE_LIMIT_PAUSE_MS, BROADCAST_API_HEADERS, LOAD_MESSAGES, LOAD_SETTLE_MS, LOAD_DELIVERY_SLO,
} from "./src/context.ts";
import type { Metric, SuiteDescriptor } from "./src/runner.ts";
import { initOtel, flushOtel, patchFetch, log, test, suite, printSummary, results, createSuiteTest } from "./src/runner.ts";
import type { TableName } from "./src/helpers.ts";
import {
  sleep, randomTopic, settle, measureThroughput, waitFor, stopClient, signInUser, waitForSubscribed,
  openChannel, openPostgresChannel, REPLICATION_READY_CONFIG, openReplicationChannel,
  executeInsert, executeUpdate, executeDelete,
} from "./src/helpers.ts";
import { setup, cleanup } from "./src/fixtures.ts";
import { broadcastBinary } from "./src/suites/broadcast-binary.ts";
import { authorization } from "./src/suites/authorization.ts";
import { loadBroadcastFromDb } from "./src/suites/load-broadcast-from-db.ts";
import { loadBroadcastReplay } from "./src/suites/load-broadcast-replay.ts";
import { connection } from "./src/suites/connection.ts";
import { loadPresence } from "./src/suites/load-presence.ts";
import { broadcast } from "./src/suites/broadcast.ts";
import { presence } from "./src/suites/presence.ts";
import { loadBroadcast } from "./src/suites/load-broadcast.ts";
import { broadcastChanges } from "./src/suites/broadcast-changes.ts";
import { loadPostgresChanges } from "./src/suites/load-postgres-changes.ts";
import { postgresChanges } from "./src/suites/postgres-changes.ts";
import { broadcastReplay } from "./src/suites/broadcast-replay.ts";
import { postgresChangesFilters } from "./src/suites/postgres-changes-filters.ts";


const descriptors: SuiteDescriptor[] = [
  connection,
  loadPostgresChanges,
  loadPresence,
  loadBroadcast,
  loadBroadcastFromDb,
  loadBroadcastReplay,
  broadcast,
  broadcastReplay,
  presence,
  authorization,
  postgresChanges,
  postgresChangesFilters,
  broadcastChanges,
  broadcastBinary,
];

const LOAD_SUITES = descriptors.map((d) => d.name).filter((n) => n.startsWith("load"));
const FUNCTIONAL_SUITES = descriptors.map((d) => d.name).filter((n) => !n.startsWith("load"));

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
    const unknown = activeCategories.filter((c: string) => !descriptors.some((d) => d.name === c));
    if (unknown.length > 0) {
      const valid = ["functional", "load", ...descriptors.map((d) => d.name)].join(", ");
      log(`Unknown test categories: ${unknown.join(", ")}\nValid categories: ${valid}`);
      process.exit(1);
    }
  }

  const suitesToRun = activeCategories
    ? descriptors.filter((d) => activeCategories.includes(d.name))
    : descriptors;

  const needsDb = suitesToRun.some((d) => d.needsDb);

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
    for (const d of suitesToRun) await d.run({ testUser, supabase, test: createSuiteTest(d.label) });
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
