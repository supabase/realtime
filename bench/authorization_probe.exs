# Measures what the extra `:persistence` write policy probe costs on top of the `:broadcast` probe,
# and what batching the two into one call recovers.
#
# Runs against the dev tenant and the policies from examples/broadcast-persistence:
#
#     mise run db-start   # from the repo root
#     mise run setup      # from examples/broadcast-persistence
#     mix run bench/authorization_probe.exs
#
# See examples/broadcast-persistence/BENCH.md for recorded results and what they do not cover.

alias Realtime.Database
alias Realtime.Tenants
alias Realtime.Tenants.Authorization
alias Realtime.Tenants.Authorization.Policies
alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies

tenant_id = System.get_env("TENANT", "realtime-dev")

tenant =
  Tenants.get_tenant_by_external_id(tenant_id) ||
    raise "no tenant #{tenant_id}. Run `mise run db-start` from the repo root."

{:ok, db_conn} = Database.connect(tenant, "realtime_bench", :stop)

# Seeded by the example's policies.sql, as a channel member with the `agent` role.
topic = "persisted:bench"
bench_user = "33333333-3333-3333-3333-333333333333"

authorization_context =
  Authorization.build_authorization_params(%{
    tenant_id: tenant.external_id,
    topic: topic,
    headers: [],
    claims: %{sub: bench_user, role: "authenticated"},
    role: "authenticated",
    sub: bench_user
  })

broadcast_only = fn ->
  Authorization.get_write_authorizations(%Policies{}, db_conn, authorization_context, :broadcast)
end

sequential = fn ->
  {:ok, policies} =
    Authorization.get_write_authorizations(%Policies{}, db_conn, authorization_context, :broadcast)

  Authorization.get_write_authorizations(policies, db_conn, authorization_context, :persistence)
end

batched = fn ->
  Authorization.get_write_authorizations(%Policies{}, db_conn, authorization_context, [:broadcast, :persistence])
end

# Benchmarking a denial would measure the short circuit instead of the probe, so check first.
case batched.() do
  {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: true}}} ->
    :ok

  other ->
    raise """
    expected #{tenant_id} to allow both broadcast and persistence on #{topic}, got:

    #{inspect(other)}

    Run `mise run setup` from examples/broadcast-persistence.
    """
end

Benchee.run(
  %{
    "broadcast only" => broadcast_only,
    "broadcast then persistence, two calls" => sequential,
    "broadcast and persistence, one call" => batched
  },
  # A cold first scenario can read as faster than the baseline, so warm up generously.
  warmup: 3,
  time: 5,
  print: [configuration: false]
)
