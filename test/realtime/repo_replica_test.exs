defmodule Realtime.Repo.ReplicaTest do
  use ExUnit.Case
  alias Realtime.Repo.Replica

  setup do
    previous_platform = Application.get_env(:realtime, :platform)
    previous_region = Application.get_env(:realtime, :region)

    on_exit(fn ->
      Application.put_env(:realtime, :platform, previous_platform)
      Application.put_env(:realtime, :region, previous_region)
    end)
  end

  describe "handle aws platform" do
    for {region, mod} <- Replica.replicas_aws() do
      setup do
        Application.put_env(:realtime, :platform, :aws)
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

  describe "handle fly platform" do
    for {region, mod} <- Replica.replicas_fly() do
      setup do
        Application.put_env(:realtime, :platform, :fly)
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
