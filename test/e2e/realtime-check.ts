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

  await test("replayed binary messages are delivered on join", async () => {
    const sql = new SQL(DB_URL, { tls: DB_SSL || undefined });
    try {
      const event = crypto.randomUUID();
      const topic = randomTopic();
      const binary = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff]);
      let result: any = null;
      let receivedMeta: any = null;

      const since = Date.now() - 1000;
      await sql`INSERT INTO public.replay_check (id, topic, event, binary_payload)
                VALUES (${crypto.randomUUID()}, ${topic}, ${event}, ${binary}::bytea)`;

      await sleep(500);

      const receiver = supabase.channel(topic, {
        config: { private: true, broadcast: { replay: { since, limit: 1 } } },
      }).on("broadcast", { event }, (msg) => {
        result = msg.payload;
        receivedMeta = msg.meta;
      });
      const subscribeMs = await openChannel(receiver);

      const { latencyMs: replayMs } = await waitFor(() => result, "replayed binary broadcast event");

      const received = result instanceof Uint8Array ? result : new Uint8Array(result);
      assert.strictEqual(received.length, binary.length, "binary payload length mismatch");
      assert.ok(binary.every((b, i) => received[i] === b), "binary payload bytes mismatch");
      assert.strictEqual(receivedMeta?.replayed, true, "expected meta.replayed on replayed binary message");
      return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "replay", value: replayMs, unit: "ms" }];
    } finally {
      await sql.close().catch(() => {});
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


const descriptors: SuiteDescriptor[] = [
  connection,
  { name: "load-postgres-changes", label: "load-postgres-changes", needsDb: true, run: ({ testUser }) => runLoadPostgresChangesTests(testUser) },
  loadPresence,
  { name: "load-broadcast", label: "load-broadcast", needsDb: false, run: () => runLoadBroadcastTests() },
  loadBroadcastFromDb,
  loadBroadcastReplay,
  { name: "broadcast", label: "broadcast extension", needsDb: false, run: () => runBroadcastTests() },
  { name: "broadcast-replay", label: "broadcast replay", needsDb: true, run: ({ testUser, supabase }) => runBroadcastReplayTests(testUser, supabase) },
  { name: "presence", label: "presence extension", needsDb: true, run: ({ testUser, supabase }) => runPresenceTests(testUser, supabase) },
  authorization,
  { name: "postgres-changes", label: "postgres changes extension", needsDb: true, run: ({ testUser, supabase }) => runPostgresChangesTests(testUser, supabase) },
  { name: "postgres-changes-filters", label: "postgres-changes-filters", needsDb: true, run: ({ testUser, supabase }) => runPostgresChangesFiltersTests(testUser, supabase) },
  { name: "broadcast-changes", label: "broadcast changes", needsDb: true, run: ({ testUser, supabase }) => runBroadcastChangesTests(testUser, supabase) },
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
