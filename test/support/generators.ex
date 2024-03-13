defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """
  alias Realtime.Tenants.Connect
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
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "5433",
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

  def channel_fixture(tenant, override \\ %{}) do
    {:ok, pid} = Connect.connect(tenant.external_id, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    create_attrs = %{"name" => random_string()}
    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, channel} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Channels.create_channel(db_conn)

    Process.exit(pid, :normal)
    :timer.sleep(100)
    channel
  end

  def random_string(length \\ 10) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
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

  @doc """
  Creates support RLS policies given a name and params to be used by the policies
  Supported:
  * read_all_channels - Sets read all channels policy for authenticated role
  * write_all_channels - Sets write all channels policy for authenticated role
  * read_channel - Sets read channel policy for authenticated role
  * write_channel - Sets write channel policy for authenticated role
  * read_broadcast - Sets read broadcast policy for authenticated role
  * write_broadcast - Sets write broadcast policy for authenticated role
  """
  def create_rls_policies(conn, policies, params) do
    Enum.each(policies, fn policy ->
      query = policy_query(policy, params)
      Postgrex.query!(conn, query, [])
    end)
  end

  def policy_query(query, params \\ nil)

  def policy_query(:authenticated_all_channels_read, _) do
    """
    CREATE POLICY authenticated_all_channels_read
    ON realtime.channels FOR SELECT
    TO authenticated
    USING ( true );
    """
  end

  def policy_query(:authenticated_all_channels_insert, _) do
    """
    CREATE POLICY authenticated_all_channels_write
    ON realtime.channels FOR INSERT
    TO authenticated
    WITH CHECK ( true );
    """
  end

  def policy_query(:authenticated_all_channels_update, _) do
    """
    CREATE POLICY authenticated_all_channels_update
    ON realtime.channels FOR UPDATE
    TO authenticated
    USING ( true )
    WITH CHECK ( true );
    """
  end

  def policy_query(:authenticated_all_channels_delete, _) do
    """
    CREATE POLICY authenticated_all_channels_delete
    ON realtime.channels FOR DELETE
    TO authenticated
    USING ( true );
    """
  end

  def policy_query(:authenticated_read_channel, %{name: name}) do
    """
    CREATE POLICY authenticated_read_channel
    ON realtime.channels FOR SELECT
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:authenticated_write_channel, %{name: name}) do
    """
    CREATE POLICY authenticated_write_channel
    ON realtime.channels FOR UPDATE
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' )
    WITH CHECK ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:authenticated_read_broadcast, %{name: name}) do
    """
    CREATE POLICY authenticated_read_broadcast
    ON realtime.broadcasts FOR SELECT
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' );
    """
  end

  def policy_query(:authenticated_write_broadcast, %{name: name}) do
    """
    CREATE POLICY authenticated_write_broadcast
    ON realtime.broadcasts FOR UPDATE
    TO authenticated
    USING ( realtime.channel_name() = '#{name}' )
    WITH CHECK ( realtime.channel_name() = '#{name}' );
    """
  end
end
