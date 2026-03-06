defmodule Extensions.PostgresCdcRls.WorkerSupervisorTest do
  use Realtime.DataCase, async: false

  alias Extensions.PostgresCdcRls.WorkerSupervisor
  alias Extensions.PostgresCdcRls.ReplicationPoller
  alias Extensions.PostgresCdcRls.SubscriptionManager
  alias Extensions.PostgresCdcRls.SubscriptionsChecker

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    extension = hd(tenant.extensions).settings

    args =
      extension
      |> Map.put("id", tenant.external_id)
      |> Map.put("region", extension["region"])

    %{args: args, tenant: tenant}
  end

  describe "start_link/1" do
    test "starts the supervisor with all children", %{args: args} do
      pid = start_link_supervised!({WorkerSupervisor, args})

      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      assert ReplicationPoller in child_ids
      assert SubscriptionManager in child_ids
      assert SubscriptionsChecker in child_ids
    end

    test "creates ETS tables for subscribers", %{args: args} do
      pid = start_link_supervised!({WorkerSupervisor, args})

      children = Supervisor.which_children(pid)

      replication_poller_pid =
        Enum.find_value(children, fn
          {ReplicationPoller, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end)

      assert replication_poller_pid != nil
      assert Process.alive?(replication_poller_pid)
    end

    test "raises exception when tenant is not in cache" do
      args = %{
        "id" => "nonexistent_tenant_#{System.unique_integer()}",
        "region" => "us-east-1",
        "db_host" => "localhost",
        "db_name" => "realtime",
        "db_user" => "user",
        "db_password" => "pass",
        "db_port" => "5432"
      }

      {pid, ref} = spawn_monitor(fn -> WorkerSupervisor.start_link(args) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, {%Realtime.PostgresCdc.Exception{}, _}}
    end
  end

  describe "supervisor registration" do
    test "registers in syn under the tenant scope", %{args: args, tenant: tenant} do
      start_link_supervised!({WorkerSupervisor, args})

      scope = Realtime.Syn.PostgresCdc.scope(tenant.external_id)
      assert {pid, _meta} = :syn.lookup(scope, tenant.external_id)
      assert is_pid(pid)
    end
  end
end
