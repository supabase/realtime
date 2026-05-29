# Realtime Features

Realtime exposes three features over WebSockets. All three share the same connection and channel model: a client opens a single WebSocket, then joins one or more named topics (channels). Each feature is opted into per channel via the `config` payload at join time.

---

## Broadcast

Send ephemeral messages between clients subscribed to the same topic with low latency.

### How it works

1. A client sends a `broadcast` event to a channel topic.
2. The server validates the payload size against the tenant's `max_payload_size_in_kb` limit.
3. On private channels, RLS write policies are checked before the message is forwarded.
4. The message is dispatched to all other subscribers on the topic. By default, the sender is excluded.

### Configuration

Set at channel join time under `config.broadcast`:

| Key | Type | Description |
|-----|------|-------------|
| `self` | boolean | When `true`, the sender also receives its own broadcast messages. Default `false`. |
| `ack` | boolean | When `true`, the server replies with `:ok` after dispatching. Default `false` (fire-and-forget). |

### Constraints

- Payload size is capped at the tenant's `max_payload_size_in_kb` (with a ±500 byte margin).
- Rate is capped at the tenant's configured events-per-second limit. Exceeding it disconnects the client.
- On private channels, if the write policy denies access, the message is silently dropped.

---

## Presence

Track and synchronize which clients are connected, along with arbitrary metadata.

### How it works

1. A client sends a `presence` event with `track` or `untrack` action and an optional payload map.
2. `track` creates or updates the client's presence entry in a distributed ETS-backed store (Phoenix.Presence).
3. All subscribers on the topic receive a `presence_diff` message with the join/leave delta.
4. New joiners receive a `presence_state` message with the full current state for that topic.
5. `untrack` removes the entry immediately.

Presence state is keyed per client (UUID by default, or a caller-provided string via `config.presence.key`). Duplicate `track` calls with the same payload are no-ops.

### Configuration

Set at channel join time under `config.presence`:

| Key | Type | Description |
|-----|------|-------------|
| `key` | string | Custom key to identify this client's presence entry. Defaults to a generated UUID. |

### Constraints

- Payload must be a JSON object (map).
- Server-side rate limit: `max_presence_events_per_second` per tenant.
- Client-side rate limit: 5 events per 30-second window by default.
- Payload size is subject to the same `max_payload_size_in_kb` limit as Broadcast.
- On private channels, RLS read and write policies are enforced.

---

## Postgres Changes

Listen to INSERT, UPDATE, and DELETE events on Postgres tables and receive them in real time.

### How it works

1. At channel join, the client declares one or more subscriptions in `config.postgres_changes`. Each subscription specifies an event type, a table, and optional filters.
2. The server creates a `realtime.subscription` row in the tenant database for each subscription, storing the filters alongside the subscriber identity.
3. A replication poller reads changes from a logical replication slot (WAL) on a configurable interval.
4. For each WAL record, the tenant database runs `realtime.apply_rls()`, which:
   - Checks RLS policies for each subscribing role.
   - Runs `realtime.is_visible_through_filters()` to match the row against each subscription's filters.
5. Matching subscription IDs are returned alongside the change and dispatched to the appropriate clients.

### Subscription parameters

| Key | Required | Description |
|-----|----------|-------------|
| `event` | Yes | `INSERT`, `UPDATE`, `DELETE`, or `*` for all three. |
| `schema` | Yes | Database schema name (e.g. `public`). |
| `table` | No | Table name. Omit to listen to all tables in the schema. |
| `filter` | No | Filter expression (see below). |

### Filters

Filters limit which change events are delivered to a subscriber. They are evaluated inside the tenant database using the subscriber's role, so column-level privileges and RLS policies are always respected.

#### Syntax

A single filter has the form:

```
column=operator.value
```

Multiple filters are separated by commas. All conditions must be true for a change to be delivered (AND semantics):

```
col1=operator.value,col2=operator.value
```

#### Reserved characters

Values that contain reserved characters must be wrapped in double quotes:

```
col=eq."some value, with comma"
```

Reserved characters: comma (`,`), and whitespace.

#### Comparison operators

These operators cast both sides to the column's declared type before comparing.

| Operator | SQL | Description |
|----------|-----|-------------|
| `eq` | `=` | Column equals value. |
| `neq` | `!=` | Column does not equal value. |
| `lt` | `<` | Column is less than value. |
| `lte` | `<=` | Column is less than or equal to value. |
| `gt` | `>` | Column is greater than value. |
| `gte` | `>=` | Column is greater than or equal to value. |

#### List operators

The value is a parenthesised, comma-separated list: `(val1,val2,val3)`.

| Operator | SQL | Description |
|----------|-----|-------------|
| `in` | `= ANY(array)` | Column value appears in the list. |
| `not_in` | `!= ALL(array)` | Column value does not appear in the list. |

Maximum 100 values per list. The list is cast to an array of the column's type.

#### Pattern matching operators

Standard SQL pattern syntax applies: `%` matches any sequence of characters, `_` matches any single character.

| Operator | SQL | Description |
|----------|-----|-------------|
| `like` | `LIKE` | Column matches pattern (case-sensitive). |
| `ilike` | `ILIKE` | Column matches pattern (case-insensitive). |
| `not_like` | `NOT LIKE` | Column does not match pattern (case-sensitive). |
| `not_ilike` | `NOT ILIKE` | Column does not match pattern (case-insensitive). |

#### Identity operators

These operators use SQL `IS` / `IS NOT`, which handle `NULL` correctly. The value must be one of the four SQL keywords: `null`, `true`, `false`, `unknown`.

| Operator | SQL | Accepted values |
|----------|-----|-----------------|
| `is` | `IS` | `null`, `true`, `false`, `unknown` |
| `not_is` | `IS NOT` | `null`, `true`, `false`, `unknown` |

Unlike `eq`, these operators do not cast the right-hand side to the column type — they use the SQL keyword directly. This is the only correct way to test for `NULL`: `col=eq.null` translates to `col = NULL` which always yields `NULL` in SQL and never matches; `col=is.null` translates to `col IS NULL` and works as expected.

#### AND composition

All filters on a subscription are combined with AND. There is no OR operator at the filter level; OR conditions require separate subscriptions.

### DELETE events

For DELETE events, filters are applied against the old row values (the record as it existed before deletion), since the row no longer exists in the table.

### Constraints

- The subscribing role must have `SELECT` privilege on any column used in a filter.
- Filter values must be coercible to the column's type. Invalid values are rejected at subscription creation.
- `in` and `not_in` accept a maximum of 100 values.
- `is` and `not_is` only accept `null`, `true`, `false`, or `unknown`.
- RLS policies on the table are enforced — subscribers only receive rows they are permitted to read.

---

## Connection model

All three features share the same connection layer:

- One WebSocket per client.
- Up to `max_channels_per_client` topics per connection (default 100).
- JWT required on connect; re-validated every 5 minutes. Expired tokens disconnect the channel immediately.
- Token can be refreshed mid-connection by sending an `access_token` message on the socket.
