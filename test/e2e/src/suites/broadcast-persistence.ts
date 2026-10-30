import assert from "assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { EVENT_TIMEOUT_MS, RATE_LIMIT_PAUSE_MS } from "../context.ts";
import { connectDb, type Db } from "../db.ts";
import type { SuiteDescriptor } from "../runner.ts";
import { sleep, randomTopic, waitFor, stopClient, openChannel } from "../helpers.ts";

const MAX_TTL_SECONDS = 259200;

type Channel = ReturnType<SupabaseClient["channel"]>;
type Persist = Parameters<Channel["send"]>[0]["persist"];
type Received = { event: string; payload: any; meta?: { replayed?: boolean } };
type MessageRow = { extension: string; private: boolean; payload: unknown; ttl_seconds: number };

// `ack` makes the server reply once the message is handled, so send() resolves the server's error
// code when it refuses `persist` instead of dropping it silently.
async function openSender(supabase: SupabaseClient, topic: string, config: { private?: boolean; self?: boolean } = {}) {
  const { private: isPrivate = true, self = false } = config;
  const channel = supabase.channel(topic, { config: { private: isPrivate, broadcast: { ack: true, self } } });
  const subscribeMs = await openChannel(channel);
  return { channel, subscribeMs };
}

const send = (channel: Channel, event: string, persist?: Persist, payload: unknown = { message: crypto.randomUUID() }) =>
  channel.send({ type: "broadcast", event, payload, persist });

async function sendOk(channel: Channel, event: string, persist?: Persist, payload?: unknown) {
  const result = await send(channel, event, persist, payload);
  assert.strictEqual(result, "ok", `send returned ${result}`);
}

const findRow = async (sql: Db, topic: string, event: string): Promise<MessageRow | undefined> =>
  (await sql<MessageRow[]>`SELECT extension, private, payload, extract(epoch FROM expires_at - inserted_at)::float8 AS ttl_seconds
             FROM realtime.messages
             WHERE topic = ${topic} AND event = ${event}`)[0];

// Wait for the row before joining to replay it, and measure how long the insert took.
async function waitForRow(sql: Db, topic: string, event: string) {
  const start = performance.now();
  while (performance.now() - start < EVENT_TIMEOUT_MS) {
    const row = await findRow(sql, topic, event);
    if (row) return { row, latencyMs: performance.now() - start };
    await sleep(50);
  }
  throw new Error(`Timed out waiting for ${event} to be persisted on ${topic}`);
}

async function joinWithReplay(supabase: SupabaseClient, topic: string, since: number) {
  const received: Received[] = [];
  const channel = supabase
    .channel(topic, { config: { private: true, broadcast: { replay: { since, limit: 25 } } } })
    .on("broadcast", { event: "*" }, (msg) => received.push({ event: msg.event, payload: msg.payload, meta: msg.meta }));
  const subscribeMs = await openChannel(channel);
  return { received, subscribeMs };
}

export const broadcastPersistence: SuiteDescriptor = {
  name: "broadcast-persistence",
  label: "broadcast persistence",
  needsDb: true,
  runCasesInParallel: true,
  run: async ({ authedClient, test }) => {
    await test("persisted message is replayed on join", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const event = crypto.randomUUID();
        const since = Date.now() - 1000;

        const { channel: sender } = await openSender(supabase, topic);
        await sendOk(sender, event, true);
        const { row, latencyMs: persistMs } = await waitForRow(sql, topic, event);
        assert.strictEqual(row.extension, "broadcast");
        assert.strictEqual(row.private, true);
        assert.ok(Math.abs(row.ttl_seconds - MAX_TTL_SECONDS) < 5, `expected a ${MAX_TTL_SECONDS}s ttl, got ${row.ttl_seconds}s`);
        await supabase.removeChannel(sender);

        const { received, subscribeMs } = await joinWithReplay(supabase, topic, since);
        const { value: msg, latencyMs: replayMs } = await waitFor(() => received.find((m) => m.event === event) ?? null, "replayed broadcast event");

        assert.deepStrictEqual(msg.payload, row.payload);
        assert.strictEqual(msg.meta?.replayed, true);
        return [
          { label: "persist", value: persistMs, unit: "ms" },
          { label: "subscribe", value: subscribeMs, unit: "ms" },
          { label: "replay", value: replayMs, unit: "ms" },
        ];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("persisted binary message is replayed on join", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const event = crypto.randomUUID();
        const binary = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff]);
        const since = Date.now() - 1000;

        const { channel: sender } = await openSender(supabase, topic);
        await sendOk(sender, event, true, binary.buffer);
        await waitForRow(sql, topic, event);
        await supabase.removeChannel(sender);

        const { received, subscribeMs } = await joinWithReplay(supabase, topic, since);
        const { value: msg, latencyMs: replayMs } = await waitFor(() => received.find((m) => m.event === event) ?? null, "replayed binary broadcast event");

        const bytes = msg.payload instanceof Uint8Array ? msg.payload : new Uint8Array(msg.payload);
        assert.deepStrictEqual([...bytes], [...binary]);
        assert.strictEqual(msg.meta?.replayed, true);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "replay", value: replayMs, unit: "ms" }];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("message sent without persist is not stored", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const notPersisted = crypto.randomUUID();
        const persisted = crypto.randomUUID();
        const since = Date.now() - 1000;

        const { channel: sender } = await openSender(supabase, topic);
        await sendOk(sender, notPersisted);
        await sendOk(sender, persisted, true);
        await waitForRow(sql, topic, persisted);
        assert.strictEqual(await findRow(sql, topic, notPersisted), undefined, "message without persist was stored");
        await supabase.removeChannel(sender);

        const { received } = await joinWithReplay(supabase, topic, since);
        await waitFor(() => received.find((m) => m.event === persisted) ?? null, "replayed broadcast event");
        assert.deepStrictEqual(received.map((m) => m.event), [persisted]);
        return [];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("persisted message is not replayed once its ttl expires", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const expiring = crypto.randomUUID();
        const persisted = crypto.randomUUID();
        const since = Date.now() - 1000;

        const { channel: sender } = await openSender(supabase, topic);
        await sendOk(sender, expiring, { ttl: 1 });
        const { row } = await waitForRow(sql, topic, expiring);
        assert.ok(Math.abs(row.ttl_seconds - 1) < 0.5, `expected a 1s ttl, got ${row.ttl_seconds}s`);

        await sleep(2000);
        await sendOk(sender, persisted, true);
        await waitForRow(sql, topic, persisted);
        await supabase.removeChannel(sender);

        const { received } = await joinWithReplay(supabase, topic, since);
        await waitFor(() => received.find((m) => m.event === persisted) ?? null, "replayed broadcast event");
        assert.deepStrictEqual(received.map((m) => m.event), [persisted]);
        return [];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("invalid persist ttl is rejected", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const { channel: sender } = await openSender(supabase, topic);

        for (const ttl of [0, MAX_TTL_SECONDS + 1, "soon" as unknown as number]) {
          const event = crypto.randomUUID();
          const result = await send(sender, event, { ttl });
          assert.strictEqual(result, "invalid_persist_ttl", `ttl ${ttl}: got ${result}`);
          assert.strictEqual(await findRow(sql, topic, event), undefined, `ttl ${ttl}: message was stored`);
        }
        return [];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("persist on a public channel is refused", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = randomTopic();
        const event = crypto.randomUUID();
        let result: any = null;

        const { channel, subscribeMs } = await openSender(supabase, topic, { private: false, self: true });
        channel.on("broadcast", { event }, (msg) => (result = msg.payload));

        // supabase-js refuses before sending; the server ignores `persist` on a public channel.
        assert.strictEqual(await send(channel, event, true), "error");

        // Nothing to wait on for a message or row that should never appear.
        await sleep(1000);
        assert.strictEqual(result, null, "message on a public channel was sent");
        assert.strictEqual(await findRow(sql, topic, event), undefined, "message on a public channel was stored");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("message is broadcast but not stored when the policy denies persistence", async () => {
      const supabase = await authedClient();
      const sql = connectDb();
      try {
        const topic = "no-persist:" + crypto.randomUUID();
        const event = crypto.randomUUID();
        let result: any = null;

        const { channel, subscribeMs } = await openSender(supabase, topic, { self: true });
        channel.on("broadcast", { event }, (msg) => (result = msg.payload));

        assert.strictEqual(await send(channel, event, true), "persistence_unauthorized");
        const { latencyMs: eventMs } = await waitFor(() => result, "broadcast event");

        // Nothing to wait on for a row that should never appear: an allowed one shows up within milliseconds.
        await sleep(1000);
        assert.strictEqual(await findRow(sql, topic, event), undefined, "message was stored although the policy denies persistence");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }, { label: "event", value: eventMs, unit: "ms" }];
      } finally {
        await sql.end().catch(() => {});
        await stopClient(supabase);
      }
    });
  },
};
