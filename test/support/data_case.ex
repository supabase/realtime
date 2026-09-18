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
      import TestHelpers

      # The `TestHelpers` module provides backward-compatible versions of `assert_eventually/2` and
      # `refute_eventually/2`, which provide the same default timeout and interval values as the
      # old `retries: 50, sleep: 100` behavior that this test suite relied on before switching to
      # `wait_for_it`. Any options passed to these functions will override the defaults.
      import WaitForIt.Test,
        except: [assert_eventually: 1, assert_eventually: 2, refute_eventually: 1, refute_eventually: 2]

      require WaitForIt
    end
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Realtime.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  setup tags do
    setup_sandbox(tags)
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
