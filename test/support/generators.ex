defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """

  def tenant_fixture(override \\ %{}) do
    create_attrs = %{
      "external_id" => rand_string(),
      "name" => "localhost",
      "extensions" => [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "postgres",
            "db_password" => "postgres",
            "db_port" => "6432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1"
          }
        }
      ],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "jwt_secret" => "new secret"
    }

    {:ok, tenant} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Api.create_tenant()

    tenant
  end

  def rand_string(length \\ 10) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end
end
