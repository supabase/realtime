import { RealtimeClient } from "realtimejs";

import { sleep } from "https://deno.land/x/sleep/mod.ts";
import { describe, it, afterEach } from "jsr:@std/testing/bdd";
import { assertEquals } from "jsr:@std/assert";
import { expect } from "jsr:@std/expect";

import { JWTPayload, SignJWT } from "https://deno.land/x/jose@v5.9.4/index.ts";

const url = "http://realtime-dev.localhost:4000/socket";
const serviceRoleKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU3NzYzODIsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJzZXJ2aWNlX3JvbGUiLCJpYXQiOjE3NjA3NzYzODJ9.nupH8pnrOTgK9Xaq8-D4Ry-yQ-PnlXEagTVywQUJVIE"
const apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU2NjE3MjEsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNzYwNjYxNzIxfQ.PxpBoelC9vWQ2OVhmwKBUDEIKgX7MpgSdsnmXw7UdYk"; // Using secret super-secret-jwt-token-with-at-least-32-characters-long

const realtime = { vsn: '3.0.0', logger: console.log, params: { apikey: apiKey} , heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeServiceRole = { vsn: '3.0.0', logger: console.log, params: { apikey: apiKey} , heartbeatIntervalMs: 5000, timeout: 5000 };
const config = { config: { broadcast: { ack: true, self: true } } };

let supabase: RealtimeClient | null;

afterEach(async () => {
  await stopClient(supabase);
});

describe("broadcast extension", { sanitizeOps: false }, () => {
  it("user is able to receive self broadcast", { sanitizeOps: false }, async () => {
    supabase = new RealtimeClient(url, realtime);

    let result = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };

    const channel = supabase
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe();

    while (channel.state != "joined") await sleep(0.2);

    console.log(channel.state)
    await channel.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (result == null) await sleep(0.2);
    assertEquals(result, expectedPayload);
    await channel.unsubscribe();
  });

  it("user is able to use the endpoint to broadcast", async () => {
    supabase = new RealtimeClient(url, realtime);

    let result = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };
    const activeChannel = supabase
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe();

    while (activeChannel.state != "joined") await sleep(0.2);

    // Send from unsubscribed channel
    new RealtimeClient(url, realtimeServiceRole).channel(topic, config).send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (result == null) await sleep(0.2);

    assertEquals(result, expectedPayload);
    await activeChannel.unsubscribe();
  });
});

async function stopClient(supabase: RealtimeClient) {
  await supabase.removeAllChannels()
}

