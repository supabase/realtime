defmodule Realtime.Repo.ReplicaTest do
  # application env being changed
  use ExUnit.Case, async: false
  alias Realtime.Repo.Replica

  setup do
    previous_platform = Application.get_env(:realtime, :platform)
    previous_region = Application.get_env(:realtime, :region)
    previous_master_region = Application.get_env(:realtime, :master_region)

    on_exit(fn ->
      Application.put_env(:realtime, :platform, previous_platform)
      Application.put_env(:realtime, :region, previous_region)
      Application.put_env(:realtime, :master_region, previous_master_region)
    end)
  end

  describe "handle aws platform" do
    for {region, mod} <- Replica.replicas_aws() do
      setup do
        Application.put_env(:realtime, :platform, :aws)
        Application.put_env(:realtime, :master_region, "special-region")
        :ok
      end

      test "handles #{region} region" do
        Application.put_env(:realtime, :region, unquote(region))
        replica_asserts(unquote(mod), Replica.replica())
      end

      test "defaults to Realtime.Repo if region is equal to master region on #{region}" do
        Application.put_env(:realtime, :region, unquote(region))
        Application.put_env(:realtime, :master_region, unquote(region))
        replica_asserts(Realtime.Repo, Replica.replica())
      end
    end

    test "defaults to Realtime.Repo if region is not configured" do
      Application.put_env(:realtime, :region, "unknown")
      replica_asserts(Realtime.Repo, Replica.replica())
    end
  end

  describe "handle fly platform" do
    for {region, mod} <- Replica.replicas_fly() do
      setup do
        Application.put_env(:realtime, :platform, :fly)
        Application.put_env(:realtime, :master_region, "special-region")
        :ok
      end

      test "handles #{region} region" do
        Application.put_env(:realtime, :region, unquote(region))
        replica_asserts(unquote(mod), Replica.replica())
      end
    end

    test "defaults to Realtime.Repo if region is not configured" do
      Application.put_env(:realtime, :region, "unknown")
      replica_asserts(Realtime.Repo, Replica.replica())
    end
  end

  defp replica_asserts(mod, replica) do
    assert mod == replica
    assert [Ecto.Repo] == replica.__info__(:attributes) |> Keyword.get(:behaviour)
  end
end
