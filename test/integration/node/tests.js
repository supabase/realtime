import { RealtimeClient } from "@supabase/supabase-js";
import { describe, it } from "mocha";
import { strict as assert } from "assert";

const sleep = (seconds) => new Promise(resolve => setTimeout(resolve, seconds * 1000));

const withDeadline = (fn, ms) => {
  return async function(...args) {
    return Promise.race([
      fn(...args),
      new Promise((_, reject) => 
        setTimeout(() => reject(new Error(`Test timed out after ${ms}ms`)), ms)
      )
    ]);
  };
};

const url = "http://realtime-dev.localhost:4100/socket";
const serviceRoleKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU3NzYzODIsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJzZXJ2aWNlX3JvbGUiLCJpYXQiOjE3NjA3NzYzODJ9.nupH8pnrOTgK9Xaq8-D4Ry-yQ-PnlXEagTVywQUJVIE";
const apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIwNzU2NjE3MjEsInJlZiI6IjEyNy4wLjAuMSIsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNzYwNjYxNzIxfQ.PxpBoelC9vWQ2OVhmwKBUDEIKgX7MpgSdsnmXw7UdYk";

const realtimeV1 = { vsn: '1.0.0', params: { apikey: apiKey }, heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeV2 = { vsn: '2.0.0', params: { apikey: apiKey }, heartbeatIntervalMs: 5000, timeout: 5000 };
const realtimeServiceRole = { vsn: '2.0.0', logger: console.log, params: { apikey: serviceRoleKey }, heartbeatIntervalMs: 5000, timeout: 5000 };

let clientV1 = null;
let clientV2 = null;

describe("broadcast extension", function() {
  // Increase timeout for all tests in this suite
  this.timeout(10000);

  it("users with different versions can receive self broadcast", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV2 = new RealtimeClient(url, realtimeV2);
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

    while (channelV1.state !== "joined" || channelV2.state !== "joined") await sleep(0.2);

    // Send from V1 client - both should receive
    await channelV1.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (resultV1 == null || resultV2 == null) await sleep(0.2);

    assert.deepEqual(resultV1, expectedPayload);
    assert.deepEqual(resultV2, expectedPayload);

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

    assert.deepEqual(resultV1, expectedPayload2);
    assert.deepEqual(resultV2, expectedPayload2);

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await stopClient(clientV1);
    await stopClient(clientV2);
    clientV1 = null;
    clientV2 = null;
  }, 5000));

  it("v2 can send/receive binary payload", withDeadline(async () => {
    clientV2 = new RealtimeClient(url, realtimeV2);
    let result = null;
    let event = crypto.randomUUID();
    let topic = "topic:" + crypto.randomUUID();
    const expectedPayload = new ArrayBuffer(2);
    const uint8 = new Uint8Array(expectedPayload);
    uint8[0] = 125;
    uint8[1] = 255;

    const config = { config: { broadcast: { ack: true, self: true } } };

    const channelV2 = clientV2
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe();

    while (channelV2.state !== "joined") await sleep(0.2);

    await channelV2.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    while (result == null) await sleep(0.2);

    assert.deepEqual(result, expectedPayload);

    await channelV2.unsubscribe();

    await stopClient(clientV2);
    clientV2 = null;
  }, 5000));

  it("users with different versions can receive broadcasts from endpoint", withDeadline(async () => {
    clientV1 = new RealtimeClient(url, realtimeV1);
    clientV2 = new RealtimeClient(url, realtimeV2);
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

    while (channelV1.state !== "joined" || channelV2.state !== "joined") await sleep(0.2);

    // Send from unsubscribed channel - both should receive
    new RealtimeClient(url, realtimeServiceRole).channel(topic, config).httpSend(event, expectedPayload);

    while (resultV1 == null || resultV2 == null) await sleep(0.2);

    assert.deepEqual(resultV1, expectedPayload);
    assert.deepEqual(resultV2, expectedPayload);

    await channelV1.unsubscribe();
    await channelV2.unsubscribe();

    await stopClient(clientV1);
    await stopClient(clientV2);
    clientV1 = null;
    clientV2 = null;
  }, 5000));
});

async function stopClient(client) {
  if (client) {
    await client.removeAllChannels();
  }
}
