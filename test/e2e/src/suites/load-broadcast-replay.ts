import { createClient } from "@supabase/supabase-js";
import { PROJECT_URL, ANON_KEY, REALTIME_OPTS, RATE_LIMIT_PAUSE_MS, LOAD_MESSAGES, LOAD_SETTLE_MS, LOAD_DELIVERY_SLO } from "../context.ts";
import type { SuiteDescriptor } from "../runner.ts";
import { sleep, randomTopic, settle, measureThroughput, signInUser, stopClient, openChannel } from "../helpers.ts";

export const loadBroadcastReplay: SuiteDescriptor = {
  name: "load-broadcast-replay",
  label: "load-broadcast-replay",
  needsDb: true,
  run: async ({ testUser, test }) => {
    await sleep(RATE_LIMIT_PAUSE_MS);
    await test("broadcast replay throughput", async () => {
      const supabase = createClient(PROJECT_URL, ANON_KEY, { realtime: REALTIME_OPTS });
      try {
        await signInUser(supabase, testUser.email, testUser.password);
        const event = crypto.randomUUID();
        const topic = randomTopic();

        const since = Date.now() - 1000;
        await Promise.all(Array.from({ length: LOAD_MESSAGES }, (_, i) =>
          supabase.from("replay_check").insert({ id: crypto.randomUUID(), topic, event, payload: { seq: i } })
        ));

        const latencies: number[] = [];
        const replayStart = performance.now();
        const receiver = supabase.channel(topic, {
          config: { private: true, broadcast: { replay: { since, limit: 25 } } },
        }).on("broadcast", { event }, () => {
          latencies.push(performance.now() - replayStart);
        });
        await openChannel(receiver);

        await settle(() => latencies.length, LOAD_MESSAGES, LOAD_SETTLE_MS);

        return measureThroughput(latencies, LOAD_MESSAGES, "replayed broadcast events", LOAD_DELIVERY_SLO);
      } finally {
        await stopClient(supabase);
      }
    });
  },
};
