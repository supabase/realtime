defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """

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

  def random_string(length \\ 10) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end
end
