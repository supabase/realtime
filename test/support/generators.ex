defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """

  @spec tenant_fixture(map()) :: Realtime.Api.Tenant.t()
  def tenant_fixture(override \\ %{}) do
    create_attrs = %{
      "external_id" => random_string(),
      "name" => "localhost",
      "extensions" => [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "localhost",
            "db_name" => "postgres",
            "db_user" => "postgres",
            "db_password" => "postgres",
            "db_port" => "5432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "jwt_secret" => "new secret"
    }

    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, tenant} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Api.create_tenant()

    tenant
  end

  @spec channel_fixture(binary(), map()) :: Realtime.Api.Channel.t()
  def channel_fixture(tenant, override \\ %{}) do
    {:ok, conn} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    create_attrs = %{"name" => random_string()}
    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, channel} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Channels.create_channel(conn)

    channel
  end

  def random_string(length \\ 10) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end
end
