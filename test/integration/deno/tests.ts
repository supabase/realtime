import { RealtimeClient } from "npm:@supabase/supabase-js@latest";
import { sleep } from "https://deno.land/x/sleep/mod.ts";
import { describe, it } from "jsr:@std/testing/bdd";
import { assertEquals } from "jsr:@std/assert";
import { deadline } from "jsr:@std/async/deadline";
import { Client } from "jsr:@db/postgres@0.19";

const withDeadline = <Fn extends (...args: never[]) => Promise<unknown>>(fn: Fn, ms: number): Fn =>
  ((...args) => deadline(fn(...args), ms)) as Fn;

const url = "http://realtime-dev.localhost:4100/socket";
const serviceRoleKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU3NzYzODIsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJzZXJ2aWNlX3JvbGUiLCJpYXQiOjE3NjA3NzYzODJ9.nupH8pnrOTgK9Xaq8-D4Ry-yQ-PnlXEagTVywQUJVIE"
const apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU2NjE3MjEsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNzYwNjYxNzIxfQ.PxpBoelC9vWQ2OVhmwKBUDEIKgX7MpgSdsnmXw7UdYk";

const realtimeV1 = { vsn: '1.0.0', params: { apikey: apiKey } , heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeV2 = { vsn: '2.0.0', params: { apikey: apiKey } , heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeServiceRole = { vsn: '2.0.0', logger: console.log, params: { apikey: serviceRoleKey } , heartbeatIntervalMs: 5000, timeout: 5000 };

let clientV1: RealtimeClient | null;
let clientV2: RealtimeClient | null;
let dbClient: Client | null;

async function getDbClient() {
  const client = new Client({
    user: "postgres",
    password: "postgres",
    database: "postgres",
    hostname: "localhost",
    port: 5532,
  });
  await client.connect();
  return client;
}

async function cleanupTestData(client: Client, ids: number[]) {
  if (ids.length > 0) {
    await client.queryArray(
      `DELETE FROM public.test_tenant WHERE id = ANY($1)`,
      [ids]
    );
  }
}

dbClient = await getDbClient();

await dbClient.queryArray(
  `drop publication if exists supabase_realtime;
   drop table if exists public.test_tenant;
   create table public.test_tenant ( id SERIAL PRIMARY KEY, details text );
   grant all on table public.test_tenant to anon;
   grant all on table public.test_tenant to postgres;
   grant all on table public.test_tenant to authenticated;
   create publication supabase_realtime for table public.test_tenant;`,
);

describe("broadcast extension", { sanitizeOps: false, sanitizeResources: false }, () => {
  it("users with different versions can receive self broadcast", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1)
    clientV2 = new RealtimeClient(url, realtimeV2)
    let resultV1 = null;
    let resultV2 = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };
    const config = { config: { broadcast: { ack: true, self: true } } };

    const channelV1 = clientV1
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV1 = payload))
      .subscribe();

    const channelV2 = clientV2
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV2 = payload))
      .subscribe();

    while (channelV1.state != "joined" || channelV2.state != "joined") await sleep(0.2);

    // Send from V1 client - both should receive
    await channelV1.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (resultV1 == null || resultV2 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload);
    assertEquals(resultV2, expectedPayload);

    // Reset results for second test
    resultV1 = null;
    resultV2 = null;
    let expectedPayload2 = { message: crypto.randomUUID() };

    // Send from V2 client - both should receive
    await channelV2.send({
      type: "broadcast",
      event,
      payload: expectedPayload2,
    });

    while (resultV1 == null || resultV2 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload2);
    assertEquals(resultV2, expectedPayload2);

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await stopClient(clientV1);
    await stopClient(clientV2);
    clientV1 = null;
    clientV2 = null;
  }, 5000));

  it("v2 can send/receive binary payload", withDeadline(async () => {
    clientV2 = new RealtimeClient(url, realtimeV2)
    let result = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    const expectedPayload = new ArrayBuffer(2);
    const uint8 = new Uint8Array(expectedPayload); // View the buffer as unsigned 8-bit integers
    uint8[0] = 125;
    uint8[1] = 255;

    const config = { config: { broadcast: { ack: true, self: true } } };

    const channelV2 = clientV2
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe();

    while (channelV2.state != "joined") await sleep(0.2);

    await channelV2.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (result == null) await sleep(0.2);

    assertEquals(result, expectedPayload);

    await channelV2.unsubscribe();

    await stopClient(clientV2);
    clientV2 = null;
  }, 5000));

  it("users with different versions can receive broadcasts from endpoint", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1)
    clientV2 = new RealtimeClient(url, realtimeV2)
    let resultV1 = null;
    let resultV2 = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };
    const config = { config: { broadcast: { ack: true, self: true } } };

    const channelV1 = clientV1
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV1 = payload))
      .subscribe();

    const channelV2 = clientV2
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV2 = payload))
      .subscribe();

    while (channelV1.state != "joined" || channelV2.state != "joined") await sleep(0.2);

    // Send from unsubscribed channel - both should receive
    new RealtimeClient(url, realtimeServiceRole).channel(topic, config).httpSend(event, expectedPayload);

    while (resultV1 == null || resultV2 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload);
    assertEquals(resultV2, expectedPayload);

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await stopClient(clientV1);
    await stopClient(clientV2);
    clientV1 = null;
    clientV2 = null;
  }, 5000));
});

describe("postgres_changes extension", { sanitizeOps: false, sanitizeResources: false }, () => {
  it("users with different versions can receive INSERT events", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV2 = new RealtimeClient(url, realtimeV2);

    let resultV1 = null;
    let resultV2 = null;
    const testDetails = `test-insert-${crypto.randomUUID()}`;
    const createdIds: number[] = [];

    const channelV1 = clientV1
      .channel("test-channel-v1")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.new.details === testDetails) {
            resultV1 = payload;
          }
        }
      )
      .subscribe();

    const channelV2 = clientV2
      .channel("test-channel-v2")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.new.details === testDetails) {
            resultV2 = payload;
          }
        }
      )
      .subscribe();

    while (channelV1.state !== "joined" || channelV2.state !== "joined") {
      await sleep(0.2);
    }

    // Perform INSERT
    const result = await dbClient.queryObject<{ id: number }>(
      `INSERT INTO public.test_tenant (details) VALUES ($1) RETURNING id`,
      [testDetails]
    );
    createdIds.push(result.rows[0].id);

    while (resultV1 == null || resultV2 == null) {
      await sleep(0.2);
    }

    assertEquals(resultV1.new.details, testDetails);
    assertEquals(resultV2.new.details, testDetails);
    assertEquals(resultV1.eventType, "INSERT");
    assertEquals(resultV2.eventType, "INSERT");

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await cleanupTestData(dbClient, createdIds);
    await stopClient(clientV1);
    await stopClient(clientV2);

    clientV1 = null;
    clientV2 = null;
  }, 10000));

  it("users with different versions can receive UPDATE events", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV2 = new RealtimeClient(url, realtimeV2);

    let resultV1 = null;
    let resultV2 = null;
    const initialDetails = `test-initial-${crypto.randomUUID()}`;
    const updatedDetails = `test-updated-${crypto.randomUUID()}`;
    const createdIds: number[] = [];

    // Create initial record
    const insertResult = await dbClient.queryObject<{ id: number }>(
      `INSERT INTO public.test_tenant (details) VALUES ($1) RETURNING id`,
      [initialDetails]
    );
    const recordId = insertResult.rows[0].id;
    createdIds.push(recordId);

    const channelV1 = clientV1
      .channel("test-channel-v1")
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.new.id === recordId) {
            resultV1 = payload;
          }
        }
      )
      .subscribe();

    const channelV2 = clientV2
      .channel("test-channel-v2")
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.new.id === recordId) {
            resultV2 = payload;
          }
        }
      )
      .subscribe();

    while (channelV1.state !== "joined" || channelV2.state !== "joined") {
      await sleep(0.2);
    }

    // Perform UPDATE
    await dbClient.queryArray(
      `UPDATE public.test_tenant SET details = $1 WHERE id = $2`,
      [updatedDetails, recordId]
    );

    while (resultV1 == null || resultV2 == null) {
      await sleep(0.2);
    }

    assertEquals(resultV1.new.details, updatedDetails);
    assertEquals(resultV2.new.details, updatedDetails);
    assertEquals(resultV1.eventType, "UPDATE");
    assertEquals(resultV2.eventType, "UPDATE");

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await cleanupTestData(dbClient, createdIds);
    await stopClient(clientV1);
    await stopClient(clientV2);

    clientV1 = null;
    clientV2 = null;
  }, 10000));

  it("users with different versions can receive DELETE events", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV2 = new RealtimeClient(url, realtimeV2);

    let resultV1 = null;
    let resultV2 = null;
    const testDetails = `test-delete-${crypto.randomUUID()}`;

    // Create record to delete
    const insertResult = await dbClient.queryObject<{ id: number }>(
      `INSERT INTO public.test_tenant (details) VALUES ($1) RETURNING id`,
      [testDetails]
    );
    const recordId = insertResult.rows[0].id;

    const channelV1 = clientV1
      .channel("test-channel-v1")
      .on(
        "postgres_changes",
        { event: "DELETE", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.old.id === recordId) {
            resultV1 = payload;
          }
        }
      )
      .subscribe();

    const channelV2 = clientV2
      .channel("test-channel-v2")
      .on(
        "postgres_changes",
        { event: "DELETE", schema: "public", table: "test_tenant" },
        (payload) => {
          if (payload.old.id === recordId) {
            resultV2 = payload;
          }
        }
      )
      .subscribe();

    while (channelV1.state !== "joined" || channelV2.state !== "joined") {
      await sleep(0.2);
    }

    // Perform DELETE
    await dbClient.queryArray(
      `DELETE FROM public.test_tenant WHERE id = $1`,
      [recordId]
    );

    while (resultV1 == null || resultV2 == null) {
      await sleep(0.2);
    }

    assertEquals(resultV1.old.id, recordId);
    assertEquals(resultV2.old.id, recordId);
    assertEquals(resultV1.eventType, "DELETE");
    assertEquals(resultV2.eventType, "DELETE");

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await stopClient(clientV1);
    await stopClient(clientV2);

    clientV1 = null;
    clientV2 = null;
  }, 10000));
});

async function stopClient(client: RealtimeClient | null) {
  if (client) {
    await client.removeAllChannels();
  }
}
