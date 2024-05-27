defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """
  alias Realtime.Tenants.Connect
  @spec tenant_fixture(map()) :: Realtime.Api.Tenant.t()
  def tenant_fixture(override \\ %{}) do
    create_attrs = %{
      "external_id" => random_string(),
      "enable_authorization" => true,
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
      "jwt_secret" => "new secret",
      "jwt_jwks" => nil
    }

    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, tenant} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Api.create_tenant()

    tenant
  end

  def message_fixture(tenant, override \\ %{}) do
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    create_attrs = %{
      "topic" => random_string(),
      "extension" => Enum.random([:presence, :broadcast])
    }

    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, channel} =
      create_attrs
      |> Map.merge(override)
      |> Realtime.Messages.create_message(db_conn)

    Process.exit(db_conn, :normal)
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
  * read_all_topic - Sets read all topic policy for authenticated role
  * write_all_topic - Sets write all topic policy for authenticated role
  * read_topic - Sets read channel policy for authenticated role
  * write_topic - Sets write channel policy for authenticated role
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

  def policy_query(:authenticated_all_topic_read, _) do
    """
    CREATE POLICY authenticated_all_topic_read
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( true );
    """
  end

  def policy_query(:authenticated_all_topic_insert, _) do
    """
    CREATE POLICY authenticated_all_topic_write
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( true );
    """
  end

  def policy_query(:authenticated_read_topic, %{topic: name}) do
    """
    CREATE POLICY authenticated_read_topic_#{name}
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' );
    """
  end

  def policy_query(:authenticated_write_topic, %{topic: name}) do
    """
    CREATE POLICY authenticated_write_topic_#{name}
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' );
    """
  end

  def policy_query(:authenticated_read_broadcast, %{topic: name}) do
    """
    CREATE POLICY authenticated_read_broadcast_#{name}
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast' );
    """
  end

  def policy_query(:authenticated_write_broadcast, %{topic: name}) do
    """
    CREATE POLICY authenticated_write_broadcast_#{name}
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast');
    """
  end

  def policy_query(:authenticated_read_presence, %{topic: name}) do
    """
    CREATE POLICY authenticated_read_presence_#{name}
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  def policy_query(:authenticated_write_presence, %{topic: name}) do
    """
    CREATE POLICY authenticated_write_presence_#{name}
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  def policy_query(:authenticated_read_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY authenticated_read_presence_#{name}
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end

  def policy_query(:authenticated_write_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY authenticated_write_presence_#{name}
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end
end
