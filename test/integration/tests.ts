import { RealtimeClient } from "realtimejs";
import { sleep } from "https://deno.land/x/sleep/mod.ts";
import { describe, it, afterEach } from "jsr:@std/testing/bdd";
import { assertEquals } from "jsr:@std/assert";
import { expect } from "jsr:@std/expect";
import { JWTPayload, SignJWT } from "https://deno.land/x/jose@v5.9.4/index.ts";

const url = "http://realtime-dev.localhost:4000/socket";
const serviceRoleKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU3NzYzODIsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJzZXJ2aWNlX3JvbGUiLCJpYXQiOjE3NjA3NzYzODJ9.nupH8pnrOTgK9Xaq8-D4Ry-yQ-PnlXEagTVywQUJVIE"
const apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU2NjE3MjEsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNzYwNjYxNzIxfQ.PxpBoelC9vWQ2OVhmwKBUDEIKgX7MpgSdsnmXw7UdYk";

const realtimeV1 = { vsn: '1.0.0', params: { apikey: apiKey } , heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeV3 = { vsn: '3.0.0', params: { apikey: apiKey } , heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeServiceRole = { vsn: '3.0.0', logger: console.log, params: { apikey: apiKey } , heartbeatIntervalMs: 5000, timeout: 5000 };
const config = { config: { broadcast: { ack: true, self: true } } };

let clientV1: RealtimeClient | null;
let clientV3: RealtimeClient | null;

afterEach(async () => {
  await stopClient(clientV1);
  await stopClient(clientV3);
  clientV1 = null;
  clientV3 = null;
});

describe("broadcast extension", { sanitizeOps: false }, () => {
  it("users with different versions can receive self broadcast", { sanitizeOps: false }, async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV3 = new RealtimeClient(url, realtimeV3);

    let resultV1 = null;
    let resultV3 = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };

    const channelV1 = clientV1
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV1 = payload))
      .subscribe();

    const channelV3 = clientV3
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV3 = payload))
      .subscribe();

    while (channelV1.state != "joined" || channelV3.state != "joined") await sleep(0.2);

    // Send from V1 client - both should receive
    await channelV1.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (resultV1 == null || resultV3 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload);
    assertEquals(resultV3, expectedPayload);
    console.log('Sending from V1 worked');

    // Reset results for second test
    resultV1 = null;
    resultV3 = null;
    let expectedPayload2 = { message: crypto.randomUUID() };

    // Send from V3 client - both should receive
    await channelV3.send({
      type: "broadcast",
      event,
      payload: expectedPayload2,
    });

    while (resultV1 == null || resultV3 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload2);
    assertEquals(resultV3, expectedPayload2);

    await channelV1.unsubscribe();
    await channelV3.unsubscribe();
  });

  it("users with different versions can receive broadcasts from endpoint", async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV3 = new RealtimeClient(url, realtimeV3);

    let resultV1 = null;
    let resultV3 = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };

    const channelV1 = clientV1
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV1 = payload))
      .subscribe();

    const channelV3 = clientV3
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (resultV3 = payload))
      .subscribe();

    while (channelV1.state != "joined" || channelV3.state != "joined") await sleep(0.2);

    // Send from unsubscribed channel - both should receive
    new RealtimeClient(url, realtimeServiceRole).channel(topic, config).send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (resultV1 == null || resultV3 == null) await sleep(0.2);

    assertEquals(resultV1, expectedPayload);
    assertEquals(resultV3, expectedPayload);

    await channelV1.unsubscribe();
    await channelV3.unsubscribe();
  });
});

async function stopClient(client: RealtimeClient | null) {
  if (client) {
    await client.removeAllChannels();
  }
}
