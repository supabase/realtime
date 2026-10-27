# Rollcall

Rollcall is a replicated registry for state that is owned by a node and lives only
while that node lives. Each node holds a set of entries for a scope, and each 
tracker process for that scope is the authority for the entries tracked on its own node. 
Trackers exchange heartbeats with the other nodes that hold the same scope, 
replace their replicas with what the peer reports, and drop a peer's entries when it 
goes silent. There is no merge and no conflict resolution, because every entry has one owner. 

Realtime uses it for presence, with the tenant as the scope and the channel topic as the partition.

[DESIGN.md](DESIGN.md) gives the protocol. The TLA+ model that produced it is in [tla](tla).

## Installation

```elixir
def deps do
  [
    {:rollcall, "~> 0.1.0"}
  ]
end
```

