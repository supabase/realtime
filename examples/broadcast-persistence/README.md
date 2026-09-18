# Broadcast persistence, per-message opt-in

Sends two messages on one channel, one with `persist: true` and one without. Both are delivered.
Only the first lands in `realtime.messages`.

## Run it

From the repo root:

```bash
mise run db-start
```

From here:

```bash
mise run setup
```

From the repo root, in another terminal:

```bash
mise run dev
```

Then from here:

```bash
mise run demo
```

`setup` has to come before `dev`, because the server caches the feature flag at startup.

`mise run clean` drops the policies, the demo rows, and the flag.

## Files

| File | What it does |
| -- | -- |
| `policies.sql` | The RLS policies, separate ones for sending and for storing |
| `index.mjs` | Connects, sends both messages, then reads the table back |
| `BENCH.md` | What the extra policy probe costs, measured by `bench/authorization_probe.exs` |
