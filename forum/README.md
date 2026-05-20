# Forum

Forum is a scalable, distributed process-group library for Elixir/OTP.

* **`Forum.Census`** — eventually-consistent counting of group membership across the cluster. Use when you need to know "how many processes are in group X right now" without paying per-join/leave network traffic.

* Process pids never leave the node they live on.
* Group membership is partitioned locally for concurrency (one partition GenServer per scheduler by default).
* A cluster forms by all nodes starting the same scope name; nodes discover each other via Erlang distribution.

## Installation

```elixir
def deps do
  [
    {:forum, "~> 1.0"}
  ]
end
```

---

## `Forum.Census` — distributed counts

Each node holds local-only membership and broadcasts its per-group counts to every peer on a fixed interval (default 5 s). Reads aggregate the local count plus the most recent counts received from peers. The view is **eventually consistent** — a join is reflected on remote nodes after at most one broadcast interval — but the cost on the wire is constant in the number of joins/leaves, not proportional.

Start it under your supervision tree:

```elixir
children = [
  {Forum.Census, [:users, partitions: 8, broadcast_interval_in_ms: 5_000]}
]
```

Use it:

```elixir
iex> Forum.Census.join(:users, {:tenant, 123}, self())
:ok
iex> Forum.Census.local_member_count(:users, {:tenant, 123})
1
iex> Forum.Census.member_count(:users, {:tenant, 123})        # cluster-wide
3
iex> Forum.Census.member_counts(:users)
%{{:tenant, 123} => 3, {:tenant, 456} => 1}
```

When to use Census: you want counts, totals, presence-of-anyone signals, dashboards. You don't need precision on the millisecond and you don't want to fan out per-event traffic.

