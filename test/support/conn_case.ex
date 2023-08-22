defmodule RealtimeWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use RealtimeWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Generators do
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

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Generators
      alias RealtimeWeb.Router.Helpers, as: Routes

      use RealtimeWeb, :verified_routes

      # The default endpoint for testing
      @endpoint RealtimeWeb.Endpoint
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Realtime.Repo)

    unless tags[:async] do
      Sandbox.mode(Realtime.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
