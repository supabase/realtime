// Failover harness for Realtime on a database with a primary failover (for example a Multigres HA project).
//
// Subscribes to Postgres Changes, Broadcast-from-Database and a plain broadcast control channel,
// writes numbered rows at a steady rate, waits for you (or --trigger-cmd) to trigger a failover,
// and reports per stream: lost / duplicate events, the longest silent gap, time to first event
// after the trigger, and whether the stream recovered. Requires the fixtures created by
// `realtime-check` (tables pg_changes and broadcast_changes plus their policies and triggers), so run
// `realtime-check --test functional` against the project once first.
import { createClient, type RealtimeChannel, type SupabaseClient } from "@supabase/supabase-js";
import { Command } from "commander";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import postgres from "postgres";

const program = new Command()
  .requiredOption("--url <url>", "Project URL, for example https://<ref>.<domain>")
  .requiredOption("--publishable-key <key>", "Publishable (anon) key")
  .requiredOption("--secret-key <key>", "Secret (service role) key")
  .option("--db-url <url>", "Optional direct DB URL: prints primary/slot state before and after the failover")
  .option("--interval-ms <ms>", "Delay between writes", "500")
  .option("--warmup-s <s>", "Seconds of steady traffic before the trigger", "20")
  .option("--after-s <s>", "Seconds to keep writing after the trigger", "90")
  .option("--write-timeout-ms <ms>", "Per-write timeout", "10000")
  .option("--trigger-cmd <cmd>", "Shell command that triggers the failover (default: wait for Enter)")
  .option("--late-join-after-s <s>", "Seconds after the trigger to join a new Postgres Changes channel (0 disables)", "2")
  .option("--max-gap-ms <ms>", "Fail if any stream is silent longer than this", "60000")
  .option("--json <file>", "Write the full report as JSON");
program.parse();
const o = program.opts();

const url: string = o.url;
const intervalMs = Number(o.intervalMs);
const warmupMs = Number(o.warmupS) * 1000;
const afterMs = Number(o.afterS) * 1000;
const writeTimeoutMs = Number(o.writeTimeoutMs);
const maxGapMs = Number(o.maxGapMs);
const lateJoinMs = Number(o.lateJoinAfterS) * 1000;

const t0 = performance.now();
const wallStart = Date.now();
const wall = (ms: number) => new Date(wallStart + ms).toISOString();
const now = () => performance.now() - t0;
const fmt = (ms: number) => `${(ms / 1000).toFixed(1)}s`;
const log = (msg: string) => console.error(`[${fmt(now()).padStart(7)}] ${msg}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Stream = "postgres_changes" | "broadcast_from_db" | "broadcast_control";
const STREAMS: Stream[] = ["postgres_changes", "broadcast_from_db", "broadcast_control"];

const runId = crypto.randomUUID();
const topic = `topic:${runId}`;
const sent = new Map<Stream, Map<number, { at: number; ok: boolean; error?: string }>>(STREAMS.map((s) => [s, new Map()]));
const received = new Map<Stream, { seq: number; at: number }[]>(STREAMS.map((s) => [s, []]));
const events: { at: number; channel: string; what: string }[] = [];
let triggerAt: number | null = null;

// A Postgres Changes channel joined after the trigger: how long until it is subscribed, until the server
// confirms the subscription, and until the first event arrives, plus every status and system message seen.
type LateJoin = { joinedAt: number; subscribedAt: number | null; serverOkAt: number | null; firstEventAt: number | null; messages: string[] };
let late: LateJoin | null = null;

async function startLateJoin(supabase: SupabaseClient) {
  await sleep(lateJoinMs);
  const rec: LateJoin = { joinedAt: now(), subscribedAt: null, serverOkAt: null, firstEventAt: null, messages: [] };
  late = rec;
  log("late join: subscribing a new postgres_changes channel");
  supabase
    .channel(`topic:late-${runId}`)
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: `run_id=eq.${runId}` }, () => {
      rec.firstEventAt ??= now();
    })
    .on("system", "*" as any, (p: any) => {
      rec.messages.push(`${fmt(now())} system ${JSON.stringify(p)}`);
      if (p?.extension === "postgres_changes" && p?.status === "ok") rec.serverOkAt ??= now();
    })
    .subscribe((status, err) => {
      rec.messages.push(`${fmt(now())} status ${status}${err ? ` (${err.message})` : ""}`);
      if (status === "SUBSCRIBED") rec.subscribedAt ??= now();
    });
}

async function dbState(label: string) {
  if (!o.dbUrl) return null;
  const sql = postgres(o.dbUrl, { connect_timeout: 15, max: 1, onnotice: () => {} });
  try {
    // inet_server_addr() is null behind the gateway; the postmaster start time and WAL position identify the
    // backend that served the query, so a changed start time after the trigger means a different postgres answered.
    const [r] = await sql`SELECT pg_is_in_recovery() AS in_recovery, pg_postmaster_start_time()::text AS postmaster_start,
      pg_current_wal_lsn()::text AS wal_lsn,
      (SELECT count(*) FROM pg_replication_slots) AS slots,
      (SELECT string_agg(slot_name || ':' || slot_type || ':' || temporary::text || ':' || active::text, ', ') FROM pg_replication_slots) AS slot_list`;
    log(`db (${label}): ${JSON.stringify(r)}`);
    return r;
  } catch (e) {
    log(`db (${label}): unreachable (${e instanceof Error ? e.message : e})`);
    return { error: String(e) };
  } finally {
    await sql.end({ timeout: 2 }).catch(() => {});
  }
}

function watch(channel: RealtimeChannel, name: string) {
  channel.on("system", "*" as any, (p: unknown) => {
    events.push({ at: now(), channel: name, what: `system ${JSON.stringify(p)}` });
    log(`${name}: system ${JSON.stringify(p)}`);
  });
  channel.subscribe((status, err) => {
    events.push({ at: now(), channel: name, what: `status ${status}${err ? ` (${err.message})` : ""}` });
    log(`${name}: status ${status}${err ? ` (${err.message})` : ""}`);
  });
}

async function main() {
  const admin = createClient(url, o.secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = `failover-${runId}@example.com`;
  const password = crypto.randomUUID();
  const { data: created, error: createErr } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (createErr) throw new Error(`createUser failed: ${createErr.message}`);
  const userId = created.user.id;

  const supabase: SupabaseClient = createClient(url, o.publishableKey, { auth: { persistSession: false } });
  try {
    const { error: signInErr } = await supabase.auth.signInWithPassword({ email, password });
    if (signInErr) throw new Error(`signIn failed: ${signInErr.message}`);

    const before = await dbState("before");

    const parse = (stream: Stream, seq: unknown) => {
      const n = Number(seq);
      if (Number.isFinite(n)) received.get(stream)!.push({ seq: n, at: now() });
    };

    const pgc = supabase
      .channel(`topic:pgc-${runId}`, { config: { postgres_changes_options: { wait: true } } } as any)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "pg_changes", filter: `run_id=eq.${runId}` }, (p: any) =>
        parse("postgres_changes", p.new?.details));
    const bdb = supabase
      .channel(topic, { config: { private: true, broadcast: { replication_ready: true } } } as any)
      .on("broadcast", { event: "INSERT" }, (p: any) => parse("broadcast_from_db", p.payload?.record?.value));
    const ctl = supabase
      .channel(`topic:ctl-${runId}`, { config: { broadcast: { self: true, ack: true } } })
      .on("broadcast", { event: "tick" }, (p: any) => parse("broadcast_control", p.payload?.seq));
    watch(pgc, "postgres_changes");
    watch(bdb, "broadcast_from_db");
    watch(ctl, "broadcast_control");
    await sleep(8000); // let all three come up and report replication-ready
    log("channels subscribed; starting writer");

    let seq = 0;
    let stop = false;
    const record = (stream: Stream, n: number, at: number, err?: string) => sent.get(stream)!.set(n, { at, ok: !err, error: err });
    const writer = (async () => {
      while (!stop) {
        const n = ++seq;
        const at = now();
        const dbWrite = (stream: Stream, q: PromiseLike<{ error: { message: string } | null }>) =>
          Promise.resolve(q).then(
            (res) => record(stream, n, at, res.error?.message),
            (e) => record(stream, n, at, e instanceof Error ? e.message : String(e)),
          );
        void dbWrite("postgres_changes",
          supabase.from("pg_changes").insert({ value: `${runId}-${n}`, details: String(n), run_id: runId }).abortSignal(AbortSignal.timeout(writeTimeoutMs)));
        void dbWrite("broadcast_from_db",
          supabase.from("broadcast_changes").insert({ id: crypto.randomUUID(), value: String(n), topic }).abortSignal(AbortSignal.timeout(writeTimeoutMs)));
        void ctl.send({ type: "broadcast", event: "tick", payload: { seq: n } }).then(
          (res) => record("broadcast_control", n, at, res === "ok" ? undefined : String(res)),
          (e) => record("broadcast_control", n, at, e instanceof Error ? e.message : String(e)),
        );
        await sleep(intervalMs);
      }
    })();

    log(`warming up for ${fmt(warmupMs)}`);
    await sleep(warmupMs);

    if (o.triggerCmd) {
      log(`running trigger: ${o.triggerCmd}`);
      triggerAt = now();
      const child = spawn(o.triggerCmd, { shell: true, stdio: ["ignore", "inherit", "inherit"] });
      // Counted from when the trigger starts, not from when a slow trigger command returns.
      if (lateJoinMs > 0) void startLateJoin(supabase);
      await new Promise<void>((resolve) => child.on("close", (code) => { log(`trigger exited with ${code}`); resolve(); }));
    } else {
      console.error("\n>>> TRIGGER THE FAILOVER NOW, then press Enter here the moment you start it. <<<\n");
      await new Promise<void>((resolve) => process.stdin.once("data", () => resolve()));
      triggerAt = now();
      if (lateJoinMs > 0) void startLateJoin(supabase);
    }
    log("failover triggered; continuing to write");
    await sleep(afterMs);
    stop = true;
    await writer;
    await sleep(8000); // drain in-flight events
    const after = await dbState("after");

    await supabase.removeAllChannels();
    report(before, after);
  } finally {
    await supabase.removeAllChannels().catch(() => {});
    await admin.auth.admin.deleteUser(userId).catch(() => log("warning: failed to delete test user"));
    await Promise.resolve(admin.from("pg_changes").delete().eq("run_id", runId)).then(() => {}, () => {});
  }
}

function report(before: unknown, after: unknown) {
  const results: Record<string, any> = {};
  let failed = false;
  console.error("\n==== RESULT ====");
  console.error(`run started ${wall(0)}; trigger at ${triggerAt === null ? "n/a" : `${fmt(triggerAt)} (${wall(triggerAt)})`}`);
  for (const s of STREAMS) {
    const sentMap = sent.get(s)!;
    const acked = [...sentMap.entries()].filter(([, v]) => v.ok).map(([n]) => n).sort((a, b) => a - b);
    const writeErrors = [...sentMap.entries()].filter(([, v]) => !v.ok).map(([n, v]) => ({ seq: n, at: Number((v.at / 1000).toFixed(1)), error: v.error }));
    const recv = received.get(s)!.slice().sort((a, b) => a.at - b.at);
    const uniq = new Set(recv.map((r) => r.seq));
    const dupes = recv.length - uniq.size;
    const missing = acked.filter((n) => !uniq.has(n));
    // Longest silence between consecutive received events, over the whole run.
    let maxGap = 0;
    let gapStart = 0;
    for (let i = 1; i < recv.length; i++) {
      const g = recv[i].at - recv[i - 1].at;
      if (g > maxGap) { maxGap = g; gapStart = recv[i - 1].at; }
    }
    const firstAfter = triggerAt === null ? undefined : recv.find((r) => r.at > triggerAt!);
    const tail = acked.slice(-10);
    const recovered = tail.length > 0 && tail.every((n) => uniq.has(n));
    const gapOk = maxGap <= maxGapMs;
    if (!recovered || !gapOk) failed = true;
    results[s] = {
      writes_ok: acked.length,
      write_errors: writeErrors.length,
      received: uniq.size,
      duplicates: dupes,
      missing: missing.length,
      missing_range: missing.length ? `${missing[0]}..${missing[missing.length - 1]}` : null,
      longest_gap_ms: Math.round(maxGap),
      longest_gap_started_at_s: Number((gapStart / 1000).toFixed(1)),
      first_event_after_trigger_ms: firstAfter && triggerAt !== null ? Math.round(firstAfter.at - triggerAt) : null,
      recovered_last_10: recovered,
    };
    console.error(`\n${s}: ${recovered && gapOk ? "PASS" : "FAIL"}`);
    for (const [k, v] of Object.entries(results[s])) console.error(`  ${k}: ${v}`);
    if (writeErrors.length) console.error(`  first write errors: ${JSON.stringify(writeErrors.slice(0, 3))}`);
  }
  if (late !== null) {
    const l: LateJoin = late;
    const rel = (t: number | null) => (t === null ? "never" : `${((t - l.joinedAt) / 1000).toFixed(1)}s`);
    console.error(`\nlate join (joined ${fmt(l.joinedAt)}, ${fmt(l.joinedAt - (triggerAt ?? 0))} after the trigger):`);
    console.error(`  subscribed: ${rel(l.subscribedAt)}, server confirmed postgres_changes: ${rel(l.serverOkAt)}, first event: ${rel(l.firstEventAt)}`);
    for (const m of l.messages) console.error(`  ${m}`);
  }
  console.error("\nchannel events (status and system):");
  for (const e of events) console.error(`  ${fmt(e.at).padStart(7)}  ${e.channel}: ${e.what}`);
  if (o.json) writeFileSync(o.json, JSON.stringify({ runId, startedAt: wall(0), triggerAt, triggerAtWall: triggerAt === null ? null : wall(triggerAt), before, after, results, lateJoin: late, events }, null, 2));
  console.error(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
  process.exitCode = failed ? 1 : 0;
}

main().catch((e) => { console.error(e); process.exit(1); });
