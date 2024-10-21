import { load } from "https://deno.land/std@0.224.0/dotenv/mod.ts";
import {
  createClient,
  SupabaseClient,
  RealtimeChannel,
} from "npm:@supabase/supabase-js@latest";
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { describe, it } from "https://deno.land/std@0.224.0/testing/bdd.ts";
import { sleep } from "https://deno.land/x/sleep/mod.ts";

const env = await load();
const url = env["PROJECT_URL"];
const token = env["PROJECT_ANON_TOKEN"];
const realtime = { heartbeatIntervalMs: 500, timeout: 1000 };
const config = { config: { broadcast: { self: true } } };

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
  await sleep(1);
};

const executeCreateDatabaseActions = async (
  supabase: SupabaseClient,
  table: string
): Promise<number> => {
  const { data }: any = await supabase
    .from(table)
    .insert([{ value: crypto.randomUUID() }])
    .select("id");
  return data[0].id;
};

const executeModifyDatabaseActions = async (
  supabase: SupabaseClient,
  table: string,
  id: number
) => {
  await supabase
    .from(table)
    .update({ value: crypto.randomUUID() })
    .eq("id", id);

  await supabase.from(table).delete().eq("id", id);
};

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
      });

    await sleep(2);
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
    await sleep(2);
    const unsubscribedChannel = supabase.channel(topic, config);
    await unsubscribedChannel.send({
      type: "broadcast",
      event,
      payload: expectedPayload,
    });

    await sleep(1);
    await stopClient(supabase, [activeChannel, unsubscribedChannel]);
    assertEquals(result, expectedPayload);
  });
});

describe("postgres changes extension", () => {
  it("user is able to receive INSERT only events from a subscribed table with filter applied", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(
      supabase,
      "filipe@supabase.io",
      "test_test"
    );
    await supabase.realtime.setAuth(accessToken);

    let result: Array<any> = [];
    let topic = crypto.randomUUID();

    let previousId = await executeCreateDatabaseActions(supabase, "pg_changes");
    let dummyId = await executeCreateDatabaseActions(supabase, "dummy");

    const activeChannel = supabase
      .channel(topic, config)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "pg_changes",
          filter: `id=eq.${previousId + 1}`,
        },
        (payload) => result.push(payload)
      )
      .subscribe();
    await sleep(2);
    await executeCreateDatabaseActions(supabase, "pg_changes");
    await executeCreateDatabaseActions(supabase, "pg_changes");
    await sleep(2);
    await stopClient(supabase, [activeChannel]);

    assertEquals(result.length, 1);
    assertEquals(result[0].eventType, "INSERT");
    assertEquals(result[0].new.id, previousId + 1);
  });

  it("user is able to receive UPDATE only events from a subscribed table with filter applied", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(
      supabase,
      "filipe@supabase.io",
      "test_test"
    );
    await supabase.realtime.setAuth(accessToken);

    let result: Array<any> = [];
    let topic = crypto.randomUUID();

    let mainId = await executeCreateDatabaseActions(supabase, "pg_changes");
    let fakeId = await executeCreateDatabaseActions(supabase, "pg_changes");
    let dummyId = await executeCreateDatabaseActions(supabase, "dummy");

    const activeChannel = supabase
      .channel(topic, config)
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "pg_changes",
          filter: `id=eq.${mainId}`,
        },
        (payload) => result.push(payload)
      )
      .subscribe();
    await sleep(2);

    executeModifyDatabaseActions(supabase, "pg_changes", mainId);
    executeModifyDatabaseActions(supabase, "pg_changes", fakeId);
    executeModifyDatabaseActions(supabase, "dummy", dummyId);

    await sleep(2);
    await stopClient(supabase, [activeChannel]);

    assertEquals(result.length, 1);
    assertEquals(result[0].eventType, "UPDATE");
    assertEquals(result[0].new.id, mainId);
  });

  it("user is able to receive DELETE only events from a subscribed table with filter applied", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(
      supabase,
      "filipe@supabase.io",
      "test_test"
    );
    await supabase.realtime.setAuth(accessToken);

    let result: Array<any> = [];
    let topic = crypto.randomUUID();

    let mainId = await executeCreateDatabaseActions(supabase, "pg_changes");
    let fakeId = await executeCreateDatabaseActions(supabase, "pg_changes");
    let dummyId = await executeCreateDatabaseActions(supabase, "dummy");

    const activeChannel = supabase
      .channel(topic, config)
      .on(
        "postgres_changes",
        {
          event: "DELETE",
          schema: "public",
          table: "pg_changes",
          filter: `id=eq.${mainId}`,
        },
        (payload) => result.push(payload)
      )
      .subscribe();
    await sleep(2);

    executeModifyDatabaseActions(supabase, "pg_changes", mainId);
    executeModifyDatabaseActions(supabase, "pg_changes", fakeId);
    executeModifyDatabaseActions(supabase, "dummy", dummyId);

    await sleep(2);
    await stopClient(supabase, [activeChannel]);

    assertEquals(result.length, 1);
    assertEquals(result[0].eventType, "DELETE");
    assertEquals(result[0].old.id, mainId);
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

    await sleep(2);

    await stopClient(supabase, [channel]);
    assertEquals(
      result,
      `"You do not have permissions to read from this Channel topic: ${topic}"`
    );
  });

  it("user using private channel can connect if they have enough permissions", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(
      supabase,
      "filipe@supabase.io",
      "test_test"
    );
    await supabase.realtime.setAuth(accessToken);

    const channel = supabase
      .channel(crypto.randomUUID(), { config: { ...config, private: true } })
      .subscribe((status: string) =>
        assert(status == "SUBSCRIBED" || status == "CLOSED")
      );

    await sleep(2);
    await supabase.auth.signOut();
    await stopClient(supabase, [channel]);
  });
});

describe("broadcast changes", () => {
  const table = "broadcast_changes";
  const id = crypto.randomUUID();
  const originalValue = crypto.randomUUID();
  const updatedValue = crypto.randomUUID();
  let insertResult: any, updateResult: any, deleteResult: any;

  it("authenticated user receives insert broadcast change from a specific topic based on id", async () => {
    let supabase = await createClient(url, token, { realtime });
    let accessToken = await signInUser(
      supabase,
      "filipe@supabase.io",
      "test_test"
    );
    await supabase.realtime.setAuth(accessToken);

    const channel = supabase
      .channel(`event:${id}`, { config: { ...config, private: true } })
      .on("broadcast", { event: "INSERT" }, (res) => (insertResult = res))
      .on("broadcast", { event: "DELETE" }, (res) => (deleteResult = res))
      .on("broadcast", { event: "UPDATE" }, (res) => (updateResult = res))
      .subscribe(async (status) => {
        if (status == "SUBSCRIBED") {
          await sleep(1);

          await supabase.from(table).insert({ value: originalValue, id });

          await supabase
            .from(table)
            .update({ value: updatedValue })
            .eq("id", id);

          await supabase.from(table).delete().eq("id", id);
        }
      });
    await sleep(5);
    assertEquals(insertResult.payload.record.id, id);
    assertEquals(insertResult.payload.record.value, originalValue);
    assertEquals(insertResult.payload.old_record, null);
    assertEquals(insertResult.payload.operation, "INSERT");
    assertEquals(insertResult.payload.schema, "public");
    assertEquals(insertResult.payload.table, "broadcast_changes");

    assertEquals(updateResult.payload.record.id, id);
    assertEquals(updateResult.payload.record.value, updatedValue);
    assertEquals(updateResult.payload.old_record.id, id);
    assertEquals(updateResult.payload.old_record.value, originalValue);
    assertEquals(updateResult.payload.operation, "UPDATE");
    assertEquals(updateResult.payload.schema, "public");
    assertEquals(updateResult.payload.table, "broadcast_changes");

    assertEquals(deleteResult.payload.record, null);
    assertEquals(deleteResult.payload.old_record.id, id);
    assertEquals(deleteResult.payload.old_record.value, updatedValue);
    assertEquals(deleteResult.payload.operation, "DELETE");
    assertEquals(deleteResult.payload.schema, "public");
    assertEquals(deleteResult.payload.table, "broadcast_changes");

    await supabase.auth.signOut();
    await stopClient(supabase, [channel]);
  });
});
