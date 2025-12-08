# Beacon

Beacon is a scalable process group manager. The main use case for this library is to have membership counts available on the cluster without spamming whenever a process joins or leaves a group. A node can have thousands of processes joining and leaving hundreds of groups while sending just the membership count to other nodes.

The main features are:

* Process pids are available only to the node the where the processes reside;
* Groups are partitioned locally to allow greater concurrency while joining different groups;
* Group counts are periodically broadcasted (defaults to every 5 seconds) to update group membership numbers to all participating nodes;
* Sub-cluster nodes join by using same scope;

## Installation

The package can be installed by adding `beacon` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:beacon, "~> 1.0"}
  ]
end
```

## Using

Add Beacon to your application's supervision tree specifying a scope name (here it's `:users`)

```elixir
def start(_type, _args) do
  children =
    [
      {Beacon, :users},
      # Or passing options:
      # {Beacon, [:users, opts]}
      # See Beacon.start_link/2 for the options
```

Now process can join groups

```elixir
iex> pid = self()
#PID<0.852.0>
iex> Beacon.join(:users, {:tenant, 123}, pid)
:ok
iex> Beacon.local_member_count(:users, {:tenant, 123})
1
iex> Beacon.local_members(:users, {:tenant, 123})
[#PID<0.852.0>]
iex> Beacon.local_member?(:users, {:tenant, 123}, pid)
true
```

From another node part of the same scope:

```elixir
iex> Beacon.member_counts(:users)
%{{:tenant, 123} => 1}
iex> Beacon.member_count(:users, {:tenant, 123})
1
```
