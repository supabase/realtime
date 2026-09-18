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

Then from here, either the browser demo:

```bash
mise run web     # http://localhost:5173
```

or the headless script:

```bash
mise run demo
```

`setup` has to come before `dev`, because the server caches the feature flag at startup.

`mise run clean` drops the policies, the demo rows, and the flag.

## The browser demo

An AI coding session. Send a prompt and the agent answers on the same channel, from its own
connection with its own token, the way a harness process would. Every message says whether it was
saved. The retention checkbox at the top decides how much of the transcript your product keeps.
Beside the session, `Saved transcript` shows the actual rows, and `Reconnect and replay` proves
those rows are exactly what comes back.

`Under the hood` holds the technical detail: the live permission probe, the policies on
`realtime.messages`, the SQL in force (editable), and the `send()` and `select` calls.

## The policies

The demo is an AI coding harness. A human and an agent talk on the same channel, and the product
decides how much of the transcript to keep: the human's prompts only, or the whole conversation.
A checkbox rewrites the persistence policy and applies it, so the SQL on screen is always the SQL
in force.

Authorization reads your own table. `public.session_members` is keyed by the full topic, and the
policies match on `auth.uid()` and the member's role. Sign in as either party to see the same send
stored or dropped. Both can always talk; only storing changes.

That split is the point. A policy decides who may store, and it cannot see the message, so the
per-message `persist` flag decides which of their messages actually are.

With `ack: true` the server writes the row before replying and sends back its id, which the page
shows next to each send.

## Files

| File | What it does |
| -- | -- |
| `policies.sql` | The RLS policies, separate ones for sending and for storing |
| `web/` | The browser demo, served by Vite |
| `vite.config.mjs` | Dev server, plus the endpoints that sign the JWT and read the table |
| `index.mjs` | The same thing headless: sends both messages, then reads the table back |
| `BENCH.md` | What the extra policy probe costs, measured by `bench/authorization_probe.exs` |
