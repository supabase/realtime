import assert from "assert";
import { postgresChangesFilter, type SupabaseClient } from "@supabase/supabase-js";
import { POSTGRES_CHANGES_CONFIG, RATE_LIMIT_PAUSE_MS } from "../context.ts";
import type { SuiteDescriptor } from "../runner.ts";
import { sleep, randomTopic, waitFor, stopClient, openPostgresChannel, executeInsert, isolated } from "../helpers.ts";

// Inserts the rows in one statement, so they share one transaction, and returns their ids.
async function insertRows(supabase: SupabaseClient, rows: Record<string, unknown>[]): Promise<number[]> {
  const { data, error } = await supabase.from("pg_changes").insert(rows).select("id");
  if (error) throw new Error(`Error inserting into pg_changes: ${error.message}`);
  return (data as { id: number }[]).map((r) => r.id);
}

export const postgresChangesFilters: SuiteDescriptor = {
  name: "postgres-changes-filters",
  label: "postgres-changes-filters",
  needsDb: true,
  // Verified safe for internal concurrency: every test creates its own client + row
  // tags, and postgresChangesFilter() returns a fresh builder per call (no shared state).
  runCasesInParallel: true,
  run: async ({ authedClient, test }) => {
    await test("eq: delivers row equal to the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `eq_${tag}`;
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("value", value) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "eq event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("neq: delivers row not equal to the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `neq_${tag}`;
        // neq against a value nobody else inserts matches nearly every row in the
        // table, so under --parallel it also picks up every other concurrently-running
        // test's inserts. Scope it to this test's own rows (see helpers.ts `isolated`).
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().neq("value", `no_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "neq event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("lt: delivers row less than the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `a_${tag}`;
        // A bare `<` comparison against an arbitrary threshold isn't narrow: any other
        // test's random tag has a good chance of sorting below it too — scope it.
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().lt("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "lt event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("lte: delivers row less than or equal to the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `a_${tag}`;
        // Same as `lt`: a bare `<=` threshold isn't narrow against other tests' random
        // tags — scope it.
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().lte("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "lte event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("gt: delivers row greater than the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `c_${tag}`;
        // Same reasoning as `lt`/`lte`: a bare `>` threshold isn't narrow — scope it.
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().gt("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "gt event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("gte: delivers row greater than or equal to the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `c_${tag}`;
        // Same reasoning as `lt`/`lte`/`gt`: a bare `>=` threshold isn't narrow — scope it.
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().gte("value", `b_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "gte event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("in: delivers row whose value is in the list", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `in_${tag}`;
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().in("value", [value, `other_${tag}`]) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "in event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("like: delivers row matching the pattern", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `${tag}hello`;
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().like("value", `${tag}%`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "like event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("ilike: matches the pattern case-insensitively", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `${tag}HELLO`; // upper-cased value, lower-cased filter
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().ilike("value", `${tag}hello%`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "ilike event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);


    await test("is: delivers row whose nullable column is null", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `is_${tag}`; // executeInsert only sets `value`, so nullable_value stays null
        // nullable_value IS NULL matches nearly every other test's rows too (none of
        // them set it), so under --parallel this needs its own scope (see `isolated`).
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().is("nullable_value", null) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "is event");

        assert.strictEqual(result.new.nullable_value, null);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("match: delivers row matching the regex", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `${tag}abc123`;
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().match("value", `^${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "match event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("imatch: matches the regex case-insensitively", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `${tag}ABC`; // upper-cased value, lower-cased regex
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().imatch("value", `^${tag}abc`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await executeInsert(supabase, "pg_changes", value);
        await waitFor(() => result, "imatch event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("isdistinct: delivers row whose value is distinct from the literal", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `isd_${tag}`;
        // isDistinct against a value nobody else inserts matches nearly every row in
        // the table, same firehose risk as neq under --parallel — scope it.
        const { scope, row } = isolated(tag);
        let result: any = null;

        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().isDistinct("value", `other_${tag}`) }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value })]);
        await waitFor(() => result, "isdistinct event");

        assert.strictEqual(result.new.value, value);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("and: delivers only rows matching every comma-separated condition", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}both`;
        const decoy = `${tag}one`;
        const seen: string[] = [];

        // value LIKE tag%  AND  details = tag-keep
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().like("value", `${tag}%`).eq("details", `${tag}keep`) }, (p) => { seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match, details: `${tag}keep` }, // satisfies both conditions
          { value: decoy, details: `${tag}nope` }, // satisfies only the value condition
        ]);
        await waitFor(() => (seen.includes(match) ? true : null), "and event");
        await sleep(1000); // give the decoy a chance to arrive if AND were wrongly treated as OR

        assert.ok(seen.includes(match), "row matching both conditions must be delivered");
        assert.ok(!seen.includes(decoy), "row matching only one condition must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("not: excludes the negated value and delivers the rest", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const excluded = `${tag}skip`;
        const delivered = `${tag}keep`;
        const seen: string[] = [];

        // not(eq) excludes one literal and matches everything else — same firehose
        // shape as the bare `neq` test, just spelled differently — scope it.
        const { scope, row } = isolated(tag);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: scope().not("value", "eq", excluded) }, (p) => { if (p.new.value === excluded || p.new.value === delivered) seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([row({ value: excluded }), row({ value: delivered })]);
        await waitFor(() => (seen.includes(delivered) ? true : null), "not event");
        await sleep(1000); // give the excluded row a chance to arrive if the negation were ignored

        assert.ok(seen.includes(delivered), "non-matching row must be delivered");
        assert.ok(!seen.includes(excluded), "negated value must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: combines and, not and a pattern filter", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}ok`;
        const decoy = `${tag}ok2`;
        const seen: string[] = [];

        // value LIKE tag%  AND  details NOT LIKE skip%  AND  nullable_value IS NULL
        const filter = postgresChangesFilter().like("value", `${tag}%`).not("details", "like", "skip%").is("nullable_value", null);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match, details: "keep" }, // matches all three (nullable_value defaults to null)
          { value: decoy, details: "skipme" }, // fails details NOT LIKE skip%
        ]);
        await waitFor(() => (seen.includes(match) ? true : null), "compose event");
        await sleep(1000);

        assert.ok(seen.includes(match), "row matching all three conditions must be delivered");
        assert.ok(!seen.includes(decoy), "row failing the not.like condition must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: bounded range with gte and lte on the same column", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}_c`; // inside [b, d]
        const tooLow = `${tag}_a`; // below the lower bound
        const tooHigh = `${tag}_e`; // above the upper bound
        const seen: string[] = [];

        // value >= tag_b  AND  value <= tag_d
        const filter = postgresChangesFilter().gte("value", `${tag}_b`).lte("value", `${tag}_d`);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match },
          { value: tooLow },
          { value: tooHigh },
        ]);
        await waitFor(() => (seen.includes(match) ? true : null), "range event");
        await sleep(1000); // give the out-of-range rows a chance to arrive if a bound were ignored

        assert.ok(seen.includes(match), "in-range row must be delivered");
        assert.ok(!seen.includes(tooLow), "row below the lower bound must be excluded");
        assert.ok(!seen.includes(tooHigh), "row above the upper bound must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: combines in list with a like pattern across columns", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `in_${tag}`;
        const decoy = `in_${tag}`; // same value, but details fail the like condition
        const seen: string[] = [];

        // value IN (in_tag, other_tag)  AND  details LIKE keep%
        const filter = postgresChangesFilter().in("value", [match, `other_${tag}`]).like("details", "keep%");
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value === match) seen.push(p.new.details); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match, details: `keep_${tag}` }, // satisfies both conditions
          { value: decoy, details: `drop_${tag}` }, // in the list but details fail the like
        ]);
        await waitFor(() => (seen.includes(`keep_${tag}`) ? true : null), "in+like event");
        await sleep(1000);

        assert.ok(seen.includes(`keep_${tag}`), "row matching both the in list and the like pattern must be delivered");
        assert.ok(!seen.includes(`drop_${tag}`), "row failing the like pattern must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: combines neq with not.like", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}keep`;
        const decoyEq = `${tag}exact`; // fails the neq
        const decoyLike = `${tag}skipme`; // fails the not.like
        const seen: string[] = [];

        // The neq component matches nearly every other test's rows too, same firehose
        // risk as the standalone neq test — scope it (see `isolated`).
        const { scope, row } = isolated(tag);
        // value != tag-exact  AND  value NOT LIKE tag-skip%
        const filter = scope().neq("value", `${tag}exact`).not("value", "like", `${tag}skip%`);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          row({ value: match }),
          row({ value: decoyEq }),
          row({ value: decoyLike }),
        ]);
        await waitFor(() => (seen.includes(match) ? true : null), "neq+not.like event");
        await sleep(1000);

        assert.ok(seen.includes(match), "row satisfying both negations must be delivered");
        assert.ok(!seen.includes(decoyEq), "row equal to the excluded value must be excluded");
        assert.ok(!seen.includes(decoyLike), "row matching the excluded pattern must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: combines is.not.null with an ilike pattern", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}HELLO`;
        const decoyNull = `${tag}HELLO2`; // fails is.not.null (nullable_value stays null)
        const decoyLike = `${tag}WORLD`; // fails the ilike pattern
        const seen: string[] = [];

        // nullable_value IS NOT NULL  AND  value ILIKE tag-hello%
        const filter = postgresChangesFilter().not("nullable_value", "is", null).ilike("value", `${tag}hello%`);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match, nullable_value: `set_${tag}` }, // satisfies both conditions
          { value: decoyNull }, // nullable_value is null
          { value: decoyLike, nullable_value: `set_${tag}` }, // fails the ilike
        ]);
        await waitFor(() => (seen.includes(match) ? true : null), "is.not.null+ilike event");
        await sleep(1000);

        assert.ok(seen.includes(match), "row with a non-null column matching the pattern must be delivered");
        assert.ok(!seen.includes(decoyNull), "row with a null column must be excluded");
        assert.ok(!seen.includes(decoyLike), "row failing the ilike pattern must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("compose: four conditions across three columns", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const match = `${tag}match`;
        const decoyValue = `${tag}other`; // fails value=eq
        const decoyDetails = `${tag}match`; // details fail the not.like
        const decoyNull = `${tag}match`; // nullable_value is null
        const seen: Array<{ value: string; details: string }> = [];

        // value = tag-match  AND  details NOT LIKE skip%  AND  details LIKE keep%  AND  nullable_value IS NOT NULL
        const filter = postgresChangesFilter().eq("value", match).not("details", "like", "skip%").like("details", "keep%").not("nullable_value", "is", null);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value.startsWith(tag)) seen.push({ value: p.new.value, details: p.new.details }); });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([
          { value: match, details: "keep_a", nullable_value: `set_${tag}` }, // satisfies all four
          { value: decoyValue, details: "keep_b", nullable_value: `set_${tag}` }, // wrong value
          { value: decoyDetails, details: "skip_c", nullable_value: `set_${tag}` }, // details start with skip
          { value: decoyNull, details: "keep_d" }, // nullable_value is null
        ]);
        await waitFor(() => (seen.some((r) => r.details === "keep_a") ? true : null), "four-condition event");
        await sleep(1000);

        assert.strictEqual(seen.length, 1, "exactly one row must satisfy all four conditions");
        assert.strictEqual(seen[0].details, "keep_a");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("select: restricts the payload to the chosen columns", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `select_${tag}`;
        let result: any = null;

        // Ask for only id + value; details and nullable_value must be absent from the payload.
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("value", value), select: ["id", "value"] }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await supabase.from("pg_changes").insert([{ value, details: `${tag}details`, nullable_value: `${tag}nv` }]);
        await waitFor(() => result, "select event");

        assert.strictEqual(result.new.value, value);
        assert.deepStrictEqual(Object.keys(result.new).sort(), ["id", "value"], "payload must only contain the selected columns");
        assert.ok(!("details" in result.new), "unselected details column must be absent");
        assert.ok(!("nullable_value" in result.new), "unselected nullable_value column must be absent");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    // Filters on jsonb and array columns (issue #2361, fixed by #2362). Before the fix, the
    // filter check read these values back from their jsonb form: a JSON string lost its quotes
    // and an array became ["a", "b"] instead of {a,b}. The check then raised, and the raise
    // dropped every change in that poll, for every subscriber of the project.

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("not.is.null: delivers row whose jsonb column holds a JSON string", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const value = `jsonstr_${tag}`;
        let result: any = null;

        // value = jsonstr_tag  AND  json_value IS NOT NULL, the filter from issue #2361
        const filter = postgresChangesFilter().eq("value", value).not("json_value", "is", null);
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter }, (p) => { if (p.new.value === value) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await insertRows(supabase, [{ value, json_value: "matched" }]); // a JS string is a JSON string in jsonb
        await waitFor(() => result, "jsonb string not.is.null event");

        assert.strictEqual(result.new.json_value, "matched");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("eq: delivers row whose jsonb column equals a JSON string", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const doc = `doc_${tag}`;
        let result: any = null;

        // The filter value is JSON text, so the string keeps its quotes: json_value = '"doc_tag"'::jsonb
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("json_value", JSON.stringify(doc)) }, (p) => { if (p.new.json_value === doc) result = p; });

        const { subscribeMs } = await openPostgresChannel(channel);
        await insertRows(supabase, [{ json_value: doc }]);
        await waitFor(() => result, "jsonb string eq event");

        assert.strictEqual(result.new.json_value, doc);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("eq: delivers insert, update and delete of a row whose array column equals the value", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const tags = [tag, "b"];
        const seen: any[] = [];

        // tags = '{tag,b}'::text[]. The builder quotes the value, because a bare comma
        // would split the filter in two. DELETE runs the filter on the old row.
        const channel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "*", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("tags", `{${tags.join(",")}}`) }, (p) => { seen.push(p); });
        const seenEvent = (eventType: string) => seen.find((p) => p.eventType === eventType) ?? null;

        const { subscribeMs } = await openPostgresChannel(channel);
        const [id] = await insertRows(supabase, [{ tags }]);
        const { value: inserted } = await waitFor(() => seenEvent("INSERT"), "array INSERT event");

        const { error: updateError } = await supabase.from("pg_changes").update({ value: `updated_${tag}` }).eq("id", id);
        if (updateError) throw new Error(`Error updating pg_changes: ${updateError.message}`);
        const { value: updated } = await waitFor(() => seenEvent("UPDATE"), "array UPDATE event");

        const { error: deleteError } = await supabase.from("pg_changes").delete().eq("id", id);
        if (deleteError) throw new Error(`Error deleting from pg_changes: ${deleteError.message}`);
        const { value: deleted } = await waitFor(() => seenEvent("DELETE"), "array DELETE event");

        assert.deepStrictEqual(inserted.new.tags, tags);
        assert.strictEqual(updated.new.value, `updated_${tag}`);
        // pg_changes has RLS enabled, so the old record of a DELETE carries only the primary key.
        assert.strictEqual(deleted.old.id, id);
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });

    await sleep(RATE_LIMIT_PAUSE_MS);

    await test("a filter on an array column does not drop changes for other subscribers", async () => {
      const supabase = await authedClient();
      try {
        const tag = crypto.randomUUID().replace(/-/g, "");
        const plain = `plain_${tag}`;
        const other = `other_${tag}`;
        let delivered: any = null;
        const arraySeen: string[] = [];

        // A plain subscriber, and a second subscriber that filters on the array column.
        // No row of this test matches the array filter, but Realtime still runs that
        // filter on every row of the table.
        const plainChannel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("value", plain) }, (p) => { if (p.new.value === plain) delivered = p; });
        const arrayChannel = supabase
          .channel(randomTopic(), POSTGRES_CHANGES_CONFIG)
          .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: postgresChangesFilter().eq("tags", `{${tag}}`) }, (p) => { arraySeen.push(p.new.value); });

        const { subscribeMs } = await openPostgresChannel(plainChannel);
        await openPostgresChannel(arrayChannel);
        // One statement is one transaction, and Realtime reads a transaction in a single
        // poll. Before the fix, the array row made the poll fail and the plain row was lost.
        await insertRows(supabase, [{ value: plain }, { value: other, tags: [other] }]);
        await waitFor(() => delivered, "plain event next to an array row");
        await sleep(1000); // give the array row a chance to arrive if the array filter were ignored

        assert.strictEqual(delivered.new.value, plain);
        assert.deepStrictEqual(arraySeen, [], "row whose array differs from the filter must be excluded");
        return [{ label: "subscribe", value: subscribeMs, unit: "ms" }];
      } finally {
        await stopClient(supabase);
      }
    });
  },
};
