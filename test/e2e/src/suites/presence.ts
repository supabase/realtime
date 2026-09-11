import assert from "assert";
import { createClient } from "@supabase/supabase-js";
import { PROJECT_URL, ANON_KEY, REALTIME_OPTS, RATE_LIMIT_PAUSE_MS } from "../context.ts";
import type { SuiteDescriptor } from "../runner.ts";
import { sleep, randomTopic, waitFor, signInUser, stopClient, openChannel } from "../helpers.ts";

export const presence: SuiteDescriptor = {
  name: "presence",
  label: "presence extension",
  needsDb: true,
  run: async ({ testUser, test }) => {
    await test("user is able to receive presence updates", async () => {
      const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
      try {
        await signInUser(supabase, testUser.email, testUser.password);
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
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("user is able to receive presence updates on private channels", async () => {
      const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
      try {
        await signInUser(supabase, testUser.email, testUser.password);

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
        await stopClient(supabase);
      }
    });
  },
};
