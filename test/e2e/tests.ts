import { load } from "https://deno.land/std@0.224.0/dotenv/mod.ts";
import {
  createClient,
  SupabaseClient,
  RealtimeChannel,
} from "npm:@supabase/supabase-js@2.44.1";
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { describe, it } from "https://deno.land/std@0.224.0/testing/bdd.ts";
import { sleep } from "https://deno.land/x/sleep/mod.ts";

const signInUser = async (
  supabase: SupabaseClient,
  email: string,
  password: string
) => {
  const { data } = await supabase.auth.signInWithPassword({ email, password });
  return data!.session!.access_token;
};

const stopClient = async (
  supabase: SupabaseClient,
  channels: RealtimeChannel[]
) => {
  await sleep(1);
  channels.forEach((channel) => {
    channel.unsubscribe();
    supabase.removeChannel(channel);
  });
  supabase.realtime.disconnect(1000, "test done");
  supabase.auth.stopAutoRefresh();
  await sleep(2);
};

const env = await load();
const url = env["PROJECT_URL"];
const token = env["PROJECT_ANON_TOKEN"];
const realtime = { heartbeatIntervalMs: 1000, timeout: 1000 };
const config = { config: { broadcast: { self: true } } };

describe("broadcast extension", () => {
  it("user is able to receive self broadcast", async () => {
    let supabase = await createClient(url, token, { realtime });
    let result = null;
    let event = crypto.randomUUID();
    let topic = crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };

    const channel = supabase
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe(async (status: string) => {
        if (status == "SUBSCRIBED") {
          await channel.send({
            type: "broadcast",
            event,
            payload: expectedPayload,
          });
        }
        assert(status == "SUBSCRIBED" || status == "CLOSED");
      });

    await sleep(1);
    await stopClient(supabase, [channel]);
    assertEquals(result, expectedPayload);
  });

  it("user is able to use the endpoint to broadcast", async () => {
    let supabase = await createClient(url, token, { realtime });
    let result = null;
    let event = crypto.randomUUID();
    let topic = crypto.randomUUID();
    let expectedPayload = { message: crypto.randomUUID() };

    const activeChannel = supabase
      .channel(topic, config)
      .on("broadcast", { event }, ({ payload }) => (result = payload))
      .subscribe();
    await sleep(1);
    const unsubscribedChannel = supabase.channel(topic, config);
    await unsubscribedChannel.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    await sleep(2);
    await stopClient(supabase, [activeChannel, unsubscribedChannel]);
    assertEquals(result, expectedPayload);
  });
});

describe("authorization check", () => {
  it("user using private channel cannot connect if does not have enough permissions", async () => {
    let supabase = await createClient(url, token, { realtime });
    let result: any = null;
    let topic = crypto.randomUUID();

    const channel = supabase
      .channel(topic, { config: { ...config, private: true } })
      .subscribe((status: string, err: any) => {
        if (status == "CHANNEL_ERROR") {
          result = err.message;
        }
        assert(status == "CHANNEL_ERROR" || status == "CLOSED");
      });

    await sleep(1);

    await stopClient(supabase, [channel]);
    assertEquals(
      result,
      '"You do not have permissions to read from this Topic"'
    );
  });

  it("user using private channel can connect if they have enough permissions", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(supabase, "test1@test.com", "test_test");
    await supabase.realtime.setAuth(accessToken);

    const channel = supabase
      .channel(crypto.randomUUID(), { config: { ...config, private: true } })
      .subscribe((status: string) =>
        assert(status == "SUBSCRIBED" || status == "CLOSED")
      );

    await sleep(1);
    await supabase.auth.signOut();
    await stopClient(supabase, [channel]);
  });
});
