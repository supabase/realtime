defmodule Realtime.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.
  You may define functions here to be used as helpers in
  your tests.
  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Realtime.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Realtime.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Realtime.DataCase
      import Generators
      import TenantConnection

      # Use Record module to extract fields of the Span record from the opentelemetry dependency.
      require Record
      @span_fields Record.extract(:span, from: "deps/opentelemetry/include/otel_span.hrl")
      @status_fields Record.extract(:status, from: "deps/opentelemetry_api/include/opentelemetry.hrl")
      # Define macros for span and span_status
      Record.defrecordp(:span, @span_fields)
      Record.defrecordp(:status, @status_fields)
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Realtime.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
