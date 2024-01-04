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
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Realtime.Repo)

    unless tags[:async] do
      Sandbox.mode(Realtime.Repo, {:shared, self()})
    end

    :ok
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

  def clean_table(db_conn, schema, table) do
    %{rows: rows} =
      Postgrex.query!(
        db_conn,
        "SELECT policyname FROM pg_policies WHERE schemaname = '#{schema}' and tablename = '#{table}'",
        []
      )

    rows
    |> List.flatten()
    |> Enum.each(fn name ->
      Postgrex.query!(db_conn, "DROP POLICY IF EXISTS #{name} ON #{schema}.#{table}", [])
    end)

    Postgrex.query!(db_conn, "TRUNCATE TABLE #{schema}.#{table}", [])
    Postgrex.query!(db_conn, "ALTER SEQUENCE #{schema}.#{table}_id_seq RESTART WITH 1", [])
  end

  def create_rls_policy(conn, policy, params \\ nil)

  def create_rls_policy(conn, :select_authenticated_role_on_channel_name, %{name: name}) do
    Postgrex.query!(
      conn,
      """
      create policy select_authenticated_role
      on realtime.channels for select
      to authenticated
      using ( realtime.channel_name() = '#{name}' );
      """,
      []
    )
  end

  def create_rls_policy(conn, :select_authenticated_role, _) do
    Postgrex.query!(
      conn,
      """
      create policy select_authenticated_role
      on realtime.channels for select
      to authenticated
      using ( true );
      """,
      []
    )
  end
end
