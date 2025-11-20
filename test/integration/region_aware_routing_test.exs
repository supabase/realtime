defmodule Realtime.Integration.RegionAwareRoutingTest do
  use Realtime.DataCase, async: false
  use Mimic

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.GenRpc
  alias Realtime.Nodes

  setup do
    # Configure test runner as non-master region (eu-west-1) with master_region = us-east-1
    original_master_region = Application.get_env(:realtime, :master_region)

    Application.put_env(:realtime, :master_region, "eu-west-2")

    # Start peer node as master region (us-east-1)
    # The master node will automatically register itself in RegionNodes on startup
    {:ok, master_node} =
      Clustered.start(nil,
        extra_config: [
          {:realtime, :region, "eu-west-2"},
          {:realtime, :master_region, "eu-west-2"}
        ]
      )

    Process.sleep(100)

    on_exit(fn ->
      Application.put_env(:realtime, :master_region, original_master_region)
      Clustered.stop()
    end)

    %{master_node: master_node}
  end

  test "create_tenant automatically routes to master region", %{master_node: master_node} do
    external_id = "test_routing_#{System.unique_integer([:positive])}"

    attrs = %{
      "external_id" => external_id,
      "name" => external_id,
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100
    }

    Mimic.expect(Realtime.GenRpc, :call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :insert
      assert opts[:tenant_id] == external_id

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)

    result = Api.create_tenant(attrs)

    assert {:ok, %Tenant{} = tenant} = result
    assert tenant.external_id == external_id

    assert Realtime.Repo.get_by(Tenant, external_id: external_id)
  end

  test "update_tenant automatically routes to master region", %{master_node: master_node} do
    # Create tenant on master node first
    tenant_attrs = %{
      "external_id" => "test_update_#{System.unique_integer([:positive])}",
      "name" => "original",
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100
    }

    Realtime.GenRpc
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :insert
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :update
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)

    tenant = tenant_fixture(tenant_attrs)

    new_name = "updated_via_routing"
    result = Api.update_tenant(tenant, %{name: new_name})

    assert {:ok, %Tenant{} = updated} = result
    assert updated.name == new_name

    reloaded = Realtime.Repo.get(Tenant, tenant.id)
    assert reloaded.name == new_name
  end

  test "delete_tenant_by_external_id automatically routes to master region", %{master_node: master_node} do
    # Create tenant on master node first
    tenant_attrs = %{
      "external_id" => "test_delete_#{System.unique_integer([:positive])}",
      "name" => "to_delete",
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100
    }

    Realtime.GenRpc
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :insert
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :delete_all
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)

    tenant = tenant_fixture(tenant_attrs)

    result = Api.delete_tenant_by_external_id(tenant.external_id)

    assert result == true

    refute Realtime.Repo.get(Tenant, tenant.id)
  end

  test "update_migrations_ran automatically routes to master region", %{master_node: master_node} do
    # Create tenant on master node first
    tenant_attrs = %{
      "external_id" => "test_migrations_#{System.unique_integer([:positive])}",
      "name" => "migrations_test",
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100,
      "migrations_ran" => 0
    }

    Realtime.GenRpc
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :insert
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)
    |> Mimic.expect(:call, fn node, mod, func, args, opts ->
      assert node == master_node
      assert mod == Realtime.Repo
      assert func == :update!
      assert opts[:tenant_id] == tenant_attrs["external_id"]

      call_original(GenRpc, :call, [node, mod, func, args, opts])
    end)

    tenant = tenant_fixture(tenant_attrs)

    new_migrations_ran = 5
    result = Api.update_migrations_ran(tenant.external_id, new_migrations_ran)

    assert %Tenant{} = updated = result
    assert updated.migrations_ran == new_migrations_ran

    reloaded = Realtime.Repo.get(Tenant, tenant.id)
    assert reloaded.migrations_ran == new_migrations_ran
  end

  test "returns error when Nodes.node_from_region returns {:error, :not_available}" do
    external_id = "test_error_node_unavailable_#{System.unique_integer([:positive])}"

    attrs = %{
      "external_id" => external_id,
      "name" => external_id,
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100
    }

    Mimic.expect(Nodes, :node_from_region, fn _region, _key -> {:error, :not_available} end)
    result = Api.create_tenant(attrs)
    assert {:error, :not_available} = result
  end

  test "returns error when GenRpc.call returns {:error, :rpc_error, reason}" do
    external_id = "test_error_rpc_error_#{System.unique_integer([:positive])}"
    rpc_error_reason = :timeout

    attrs = %{
      "external_id" => external_id,
      "name" => external_id,
      "jwt_secret" => "secret",
      "public_key" => "public",
      "extensions" => [],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "max_concurrent_users" => 200,
      "max_events_per_second" => 100
    }

    Mimic.expect(GenRpc, :call, fn _node, _mod, _func, _args, _opts -> {:error, :rpc_error, rpc_error_reason} end)
    result = Api.create_tenant(attrs)
    assert {:error, ^rpc_error_reason} = result
  end
end
