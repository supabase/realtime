defmodule Generators do
  @moduledoc """
  Data genarators for tests.
  """

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database

  @spec tenant_fixture(map()) :: Realtime.Api.Tenant.t()
  def tenant_fixture(override \\ %{}) do
    port = Enum.random(5500..9000)

    create_attrs = %{
      "external_id" => random_string(),
      "name" => "tenant",
      "extensions" => [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "#{port}",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "publication" => "supabase_realtime_test",
            "ssl_enforced" => false
          }
        }
      ],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "jwt_secret" => "new secret",
      "jwt_jwks" => nil
    }

    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()
    {:ok, tenant} = create_attrs |> Map.merge(override) |> Realtime.Api.create_tenant()

    tenant
  end

  @spec message_fixture(Realtime.Api.Tenant.t()) :: any()
  def message_fixture(tenant, override \\ %{}) do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    Realtime.Tenants.Migrations.create_partitions(db_conn)

    create_attrs = %{
      "topic" => random_string(),
      "extension" => Enum.random([:presence, :broadcast])
    }

    override = override |> Enum.map(fn {k, v} -> {"#{k}", v} end) |> Map.new()

    {:ok, channel} =
      create_attrs
      |> Map.merge(override)
      |> TenantConnection.create_message(db_conn)

    Process.exit(db_conn, :normal)
    channel
  end

  def random_string(length \\ 20) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end

  def clean_table(db_conn, schema, table) do
    Database.transaction(db_conn, fn transaction_conn ->
      %{rows: rows} =
        Postgrex.query!(
          transaction_conn,
          "SELECT policyname FROM pg_policies WHERE schemaname = '#{schema}' and tablename = '#{table}'",
          []
        )

      rows
      |> List.flatten()
      |> Enum.each(fn name ->
        Postgrex.query!(
          transaction_conn,
          "DROP POLICY IF EXISTS \"#{name}\" ON #{schema}.#{table}",
          []
        )
      end)

      Postgrex.query!(transaction_conn, "TRUNCATE TABLE #{schema}.#{table} CASCADE", [])
    end)
  end

  def create_messages_partitions(db_conn, start_date, end_date) do
    Enum.each(Date.range(start_date, end_date), fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      Postgrex.query!(
        db_conn,
        """
        CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
        PARTITION OF realtime.messages
        FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
        """,
        []
      )
    end)
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
    query = """
    CREATE OR REPLACE FUNCTION test_log_error() RETURNS boolean AS $$
    BEGIN
    RAISE EXCEPTION 'test error';
    RETURN TRUE;
    END$$ LANGUAGE plpgsql;
    """

    Postgrex.query!(conn, query, [])

    Enum.each(policies, fn policy ->
      query = policy_query(policy, params)
      Postgrex.query!(conn, query, [])
    end)
  end

  def policy_query(query, params \\ nil)

  def policy_query(:authenticated_all_topic_read, _) do
    """
    CREATE POLICY "authenticated_all_topic_read"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( true );
    """
  end

  def policy_query(:authenticated_all_topic_insert, _) do
    """
    CREATE POLICY "authenticated_all_topic_write"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( true );
    """
  end

  def policy_query(:authenticated_read_topic, %{topic: name}) do
    """
    CREATE POLICY "authenticated_read_topic_#{name}"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' );
    """
  end

  def policy_query(:authenticated_write_topic, %{topic: name}) do
    """
    CREATE POLICY "authenticated_write_topic_#{name}"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' );
    """
  end

  def policy_query(:authenticated_read_broadcast, %{topic: name}) do
    """
    CREATE POLICY "authenticated_read_broadcast_#{name}"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast' );
    """
  end

  def policy_query(:authenticated_write_broadcast, %{topic: name}) do
    """
    CREATE POLICY "authenticated_write_broadcast_#{name}"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast');
    """
  end

  def policy_query(:authenticated_read_presence, %{topic: name}) do
    """
    CREATE POLICY "authenticated_read_presence_#{name}"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  def policy_query(:authenticated_write_presence, %{topic: name}) do
    """
    CREATE POLICY "authenticated_write_presence_#{name}"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  def policy_query(:authenticated_read_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY "authenticated_read_presence_#{name}"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end

  def policy_query(:authenticated_write_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY "authenticated_write_presence_#{name}"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end

  def policy_query(:broken_read_presence, _) do
    """
    CREATE POLICY "authenticated_read_presence"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (  (SELECT test_log_error())  );
    """
  end

  def policy_query(:broken_write_presence, _) do
    """
    CREATE POLICY "authenticated_write_presence"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( (SELECT test_log_error()) );
    """
  end

  def generate_jwt_token(secret, claims \\ %{role: "authenticated", exp: System.system_time(:second) + 100_000})

  def generate_jwt_token(%Tenant{} = tenant, claims) do
    secret = Crypto.decrypt!(tenant.jwt_secret)
    generate_jwt_token(secret, claims)
  end

  def generate_jwt_token(secret, claims) when is_binary(secret) do
    signer = Joken.Signer.create("HS256", secret)
    {:ok, claims} = Joken.generate_claims(%{}, claims)
    {:ok, jwt, _} = Joken.encode_and_sign(claims, signer)
    jwt
  end
end
