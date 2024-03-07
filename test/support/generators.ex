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
