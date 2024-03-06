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

    Postgrex.query!(db_conn, "TRUNCATE TABLE #{schema}.#{table} CASCADE", [])
    Postgrex.query!(db_conn, "ALTER SEQUENCE #{schema}.#{table}_id_seq RESTART WITH 1", [])
  end

  def create_rls_policies(conn, policies, params) do
    Enum.each(policies, fn policy ->
      query = policy_query(policy, params)
      Postgrex.query!(conn, query, [])
    end)
  end

  def policy_query(query, params \\ nil)

  def policy_query(:read_all_channels, _) do
    """
    CREATE POLICY select_authenticated_role
    ON realtime.channels FOR SELECT
    TO authenticated
    USING ( true );
    """
  end

  def policy_query(:write_all_channels, _) do
    """
    CREATE POLICY write_authenticated_role
    ON realtime.channels FOR UPDATE
    TO authenticated
    USING ( true )
    WITH CHECK ( true );
    """
  end

  def policy_query(:read_channel, %{name: name}) do
    """
    CREATE POLICY select_authenticated_role
    ON realtime.channels FOR SELECT
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:write_channel, %{name: name}) do
    """
    CREATE POLICY write_authenticated_role
    ON realtime.channels FOR UPDATE
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' )
    WITH CHECK ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:read_broadcast, %{name: name}) do
    """
    CREATE POLICY broadcast_read_enabled_authenticated_role_on_channel_name
    ON realtime.broadcasts FOR SELECT
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:write_broadcast, %{name: name}) do
    """
    CREATE POLICY broadcast_write_enabled_authenticated_role_on_channel_name
    ON realtime.broadcasts FOR UPDATE
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' )
    WITH CHECK ( realtime.channel_name() = '#{name}' );
    """
  end
end
