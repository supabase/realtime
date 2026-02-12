start_time = :os.system_time(:millisecond)

alias Realtime.Api
max_cases = String.to_integer(System.get_env("MAX_CASES", "4"))
ExUnit.start(exclude: [:failing], max_cases: max_cases, capture_log: true)

max_cases = ExUnit.configuration()[:max_cases]

Containers.pull()

if System.get_env("REUSE_CONTAINERS") != "true" do
  Containers.stop_containers()
end

{:ok, _pid} = Containers.start_link(max_cases)

for tenant <- Api.list_tenants(), do: Api.delete_tenant_by_external_id(tenant.external_id)

Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :manual)

Mimic.copy(:syn)
Mimic.copy(Extensions.PostgresCdcRls)
Mimic.copy(Extensions.PostgresCdcRls.Replications)
Mimic.copy(Extensions.PostgresCdcRls.Subscriptions)
Mimic.copy(Realtime.Database)
Mimic.copy(Realtime.GenCounter)
Mimic.copy(Realtime.GenRpc)
Mimic.copy(Realtime.Nodes)
Mimic.copy(Realtime.Repo.Replica)
Mimic.copy(Realtime.RateCounter)
Mimic.copy(Realtime.Tenants.Authorization)
Mimic.copy(Realtime.Tenants.Cache)
Mimic.copy(Realtime.Tenants.Connect)
Mimic.copy(Realtime.Tenants.Migrations)
Mimic.copy(Realtime.Tenants.Rebalancer)
Mimic.copy(Realtime.Tenants.ReplicationConnection)
Mimic.copy(RealtimeWeb.ChannelsAuthorization)
Mimic.copy(RealtimeWeb.Endpoint)
Mimic.copy(RealtimeWeb.JwtVerification)
Mimic.copy(RealtimeWeb.TenantBroadcaster)

partition = System.get_env("MIX_TEST_PARTITION")
node_name = if partition, do: :"main#{partition}@127.0.0.1", else: :"main@127.0.0.1"
:net_kernel.start([node_name])
region = Application.get_env(:realtime, :region)
[{pid, _}] = :syn.members(RegionNodes, region)
:syn.update_member(RegionNodes, region, pid, fn _ -> [node: node()] end)

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")
