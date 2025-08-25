defmodule Realtime.Repo.ReplicaTest do
  use ExUnit.Case
  import Generators
  alias Realtime.Repo.Replica

  setup do
    previous_region = Application.get_env(:realtime, :region)
    on_exit(fn -> Application.put_env(:realtime, :region, previous_region) end)
  end

  describe "replica_regions/0" do
    test "returns a list of regions and their replica repositories" do
      env = %{
        "DB_HOST_REPLICA_TARGET_REGIONS_us-east-1" => "us-east-1,us-east-2,us-east-3",
        "DB_HOST_REPLICA_TARGET_REGIONS_ap_southeast-1" => "ap-southeast-1,ap-southeast-2,ap-southeast-3"
      }

      assert Replica.replica_regions(env) == %{
               "us-east-1" => Realtime.Repo.Replica.UsEast1,
               "us-east-2" => Realtime.Repo.Replica.UsEast1,
               "us-east-3" => Realtime.Repo.Replica.UsEast1,
               "ap-southeast-1" => Realtime.Repo.Replica.ApSoutheast1,
               "ap-southeast-2" => Realtime.Repo.Replica.ApSoutheast1,
               "ap-southeast-3" => Realtime.Repo.Replica.ApSoutheast1
             }
    end
  end

  describe "replica_hosts/0" do
    test "returns a list of hosts and their replica repositories" do
      env = %{
        "DB_HOST_REPLICA_HOST_us-east-1" => "127.0.0.1",
        "DB_HOST_REPLICA_HOST_us-east-2" => "127.0.0.2",
        "DB_HOST_REPLICA_HOST_us-east-3" => "127.0.0.3"
      }

      assert Replica.replica_hosts(env) == [
               {Realtime.Repo.Replica.UsEast1, "127.0.0.1"},
               {Realtime.Repo.Replica.UsEast2, "127.0.0.2"},
               {Realtime.Repo.Replica.UsEast3, "127.0.0.3"}
             ]
    end
  end

  describe "replica/0" do
    setup do
      env = %{
        "DB_HOST_REPLICA_HOST_us-east-1" => "127.0.0.1",
        "DB_HOST_REPLICA_TARGET_REGIONS_us-east-1" => "us-east-1,us-east-2,us-east-3",
        "DB_HOST_REPLICA_HOST_ap-southeast-1" => "127.0.0.2",
        "DB_HOST_REPLICA_TARGET_REGIONS_ap-southeast-1" => "ap-southeast-1,ap-southeast-2,ap-southeast-3",
        # intentionally not defined in hosts
        "DB_HOST_REPLICA_TARGET_REGIONS_eu-west-2" => "eu-west-2"
      }

      replicas_hosts = Replica.replica_hosts(env)
      replicas_regions = Replica.replica_regions(env)

      for {module, hostname} <- replicas_hosts do
        Application.put_env(:realtime, module, hostname: hostname, username: random_string(), password: random_string())
      end

      Application.put_env(:realtime, Realtime.ReplicaRepo, targets: replicas_regions)
    end

    test "returns the replica repo for the region" do
      Application.put_env(:realtime, :region, "us-east-1")
      assert Replica.replica() == Realtime.Repo.Replica.UsEast1
    end

    test "returns the default repo if the region is not configured" do
      Application.put_env(:realtime, :region, "unknown")
      assert Replica.replica() == Realtime.Repo
    end

    test "returns the default repo if the replica repo is not configured" do
      Application.put_env(:realtime, :region, "eu-west-2")
      assert Replica.replica() == Realtime.Repo
    end

    test "loads the replica repo if it is not loaded" do
      Application.put_env(:realtime, :region, "us-east-1")

      assert Replica.replica() == Realtime.Repo.Replica.UsEast1
      assert Code.ensure_loaded?(Realtime.Repo.Replica.UsEast1)
    end

    test "if repo already compiled, return the module to prevent recompilation" do
      Application.put_env(:realtime, :region, "ap-southeast-1")

      ast =
        quote do
          use Ecto.Repo,
            otp_app: :realtime,
            adapter: Ecto.Adapters.Postgres,
            read_only: true
        end

      Module.create(Realtime.Repo.Replica.ApSoutheast1, ast, Macro.Env.location(__ENV__))

      assert Replica.replica() == Realtime.Repo.Replica.ApSoutheast1
    end
  end
end
