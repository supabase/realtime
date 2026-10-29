import assert from "assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { ANON_KEY, EVENT_TIMEOUT_MS, PROJECT_URL, RATE_LIMIT_PAUSE_MS } from "../context.ts";
import { connectDb, type Db } from "../db.ts";
import type { SuiteDescriptor } from "../runner.ts";
import { sleep, randomTopic, waitFor, stopClient, openChannel } from "../helpers.ts";

const MAX_TTL_SECONDS = 259200;

type Received = { event: string; payload: any; meta?: { replayed?: boolean } };
type MessageRow = { extension: string; private: boolean; payload: unknown; ttl_seconds: number };

// Over the REST API only: supabase-js can't send `persist` on the WebSocket until
// supabase/supabase-js#2690 ships.
async function send(supabase: SupabaseClient, topic: string, event: string, query: string, body?: Uint8Array<ArrayBuffer>) {
  const { data } = await supabase.auth.getSession();
  const url = `${PROJECT_URL}/realtime/v1/api/broadcast/${encodeURIComponent(topic)}/events/${encodeURIComponent(event)}?${query}`;
  return fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": body ? "application/octet-stream" : "application/json",
      Authorization: `Bearer ${data.session!.access_token}`,
      apikey: ANON_KEY,
    },
    body: body ?? JSON.stringify({ message: crypto.randomUUID() }),
  });
}

async function sendAccepted(supabase: SupabaseClient, topic: string, event: string, query: string, body?: Uint8Array<ArrayBuffer>) {
  const res = await send(supabase, topic, event, query, body);
  assert.strictEqual(res.status, 202, `Broadcast API returned ${res.status}: ${await res.text()}`);
}

const findRow = async (sql: Db, topic: string, event: string): Promise<MessageRow | undefined> =>
  (await sql<MessageRow[]>`SELECT extension, private, payload, extract(epoch FROM expires_at - inserted_at)::float8 AS ttl_seconds
             FROM realtime.messages
             WHERE topic = ${topic} AND event = ${event}`)[0];

// The API answers 202 before the message is saved, so wait for the row before joining to replay it.
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

        await sendAccepted(supabase, topic, event, "private=true&persist=true");
        const { row, latencyMs: persistMs } = await waitForRow(sql, topic, event);
        assert.strictEqual(row.extension, "broadcast");
        assert.strictEqual(row.private, true);
        assert.ok(Math.abs(row.ttl_seconds - MAX_TTL_SECONDS) < 5, `expected a ${MAX_TTL_SECONDS}s ttl, got ${row.ttl_seconds}s`);

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

        await sendAccepted(supabase, topic, event, "private=true&persist=true", binary);
        await waitForRow(sql, topic, event);

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

        await sendAccepted(supabase, topic, notPersisted, "private=true");
        await sendAccepted(supabase, topic, persisted, "private=true&persist=true");
        await waitForRow(sql, topic, persisted);
        assert.strictEqual(await findRow(sql, topic, notPersisted), undefined, "message without persist was stored");

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

        await sendAccepted(supabase, topic, expiring, "private=true&persist[ttl]=1");
        const { row } = await waitForRow(sql, topic, expiring);
        assert.ok(Math.abs(row.ttl_seconds - 1) < 0.5, `expected a 1s ttl, got ${row.ttl_seconds}s`);

        await sleep(2000);
        await sendAccepted(supabase, topic, persisted, "private=true&persist=true");
        await waitForRow(sql, topic, persisted);

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
      try {
        for (const ttl of ["0", String(MAX_TTL_SECONDS + 1), "soon"]) {
          const res = await send(supabase, randomTopic(), crypto.randomUUID(), `private=true&persist[ttl]=${ttl}`);
          assert.strictEqual(res.status, 422, `ttl ${ttl}: expected 422, got ${res.status}`);
          assert.deepStrictEqual(await res.json(), {
            message: `persist ttl must be a positive integer of seconds from 1 to ${MAX_TTL_SECONDS}`,
          });
        }
        return [];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("persist on a public channel is rejected", async () => {
      const supabase = await authedClient();
      try {
        const res = await send(supabase, randomTopic(), crypto.randomUUID(), "persist=true");
        assert.strictEqual(res.status, 422, `expected 422, got ${res.status}`);
        assert.deepStrictEqual(await res.json(), { errors: { persist: ["can only be used on private channels"] } });
        return [];
      } finally {
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

        const channel = supabase.channel(topic, { config: { private: true } }).on("broadcast", { event }, (msg) => (result = msg.payload));
        const subscribeMs = await openChannel(channel);

        await sendAccepted(supabase, topic, event, "private=true&persist=true");
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
