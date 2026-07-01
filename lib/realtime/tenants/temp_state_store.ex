defmodule Realtime.Tenants.TempStateStore do
  @moduledoc """
  Session-local, channel-scoped key/value state backed by a PostgreSQL temporary table.

  This is an opt-in feature: a private channel asks for it through the join payload
  (`config.state.enabled = true`) and a dedicated process is started for that channel. It is only
  honoured on private (authenticated) channels because it opens a dedicated session against the
  tenant database; allowing it on public channels would let anyone spin up sessions and write to
  the tenant database.

  ## Ownership model

      one process owns one connection
      one connection owns one temp table
      all mutations go through that owner

  Each opted-in channel gets its own `Realtime.Tenants.TempStateStore` process that owns a
  dedicated Postgrex connection (pool size 1) against the tenant database. The scope is the
  *channel process* (one socket join), not the topic: two clients on the same private topic get
  two independent stores, connections and temp tables. This is per-connection scratch space, not
  shared state broadcast to a topic's subscribers.

  On connect the session is configured and the `TEMP TABLE` is created via Postgrex's
  `:after_connect` hook. The connection uses `backoff_type: :stop`, so a dropped connection is not
  retried: the store stops instead and the channel re-creates one on its next join if it still
  wants state. The temp table therefore tracks the lifetime of a single session.

  ## Per-tenant limit

  Because each store holds a dedicated tenant-database session, the number of live stores is
  capped. The cap is driven by the database itself rather than by Realtime bookkeeping: before
  starting a store, `start/4` counts the live `realtime_temp_state` sessions in the tenant
  database (`pg_stat_activity`) and compares them against a fraction of that database's
  `max_connections` (and the `max_per_tenant/0` ceiling). This is authoritative and naturally
  cluster-wide — every node's sessions appear in `pg_stat_activity` — so it guarantees the limit
  tracks real database capacity. `start/4` returns `{:error, :too_many_state_stores}` once the
  limit is reached; the channel treats that as "no store" and joins without one.

  Because the table is a `TEMP TABLE` it lives in `pg_temp` and is therefore:

    * connection-local
    * disposable and rebuildable
    * gone when the session ends

  The supported SQL surface is intentionally tiny and only ever touches the channel's own
  temp table by primary key: `put`, `insert`, `update`, `delete`, `get`, `clear` and `count`.
  No joins, no sorts, no aggregation beyond a single `count(*)` health check, and no access to
  any other table.

  ## Input limits

  To keep unbounded data out of the tenant's temp space, writes are bounded in the application:

    * keys larger than 1024 bytes are rejected (`:key_too_large`)
    * values larger than `max_value_bytes/0` are rejected (`:value_too_large`)
    * a store holds at most `max_keys/0` keys; a new key past that returns `:limit_reached`
      (updates to existing keys are still allowed)

  These are enforced regardless of the session guardrails below, which cannot be fully relied on.

  > #### Not guaranteed RAM-only {: .warning}
  >
  > PostgreSQL temp tables are not strictly guaranteed to be memory-only. We raise `temp_buffers`
  > and keep the workload to primary-key access. We also *attempt* a low `temp_file_limit`, but
  > that parameter is superuser-only (`SUSET`) and is silently skipped for the least-privilege
  > tenant role used at runtime — so it is not a reliable guard. The application-level input limits
  > above are what actually bound storage; core PostgreSQL provides no hard "RAM-only" mode.
  """
  use GenServer, restart: :temporary
  use Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Database

  @application_name "realtime_temp_state"
  @default_max_per_tenant 10
  @default_max_connection_fraction 0.1
  @default_max_value_bytes 256_000
  @default_max_keys 10_000
  @max_key_bytes 1024

  @capacity_query """
  SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE application_name = $1 AND datname = current_database()),
    current_setting('max_connections')::int
  """

  @session_settings [
    "SET temp_buffers = '32MB'",
    "SET work_mem = '4MB'",
    "SET temp_file_limit = '1MB'"
  ]

  @type version :: non_neg_integer()
  @type expected :: version() | nil

  @type command ::
          {:put, key :: String.t(), value :: term()}
          | {:insert, key :: String.t(), value :: term()}
          | {:update, key :: String.t(), value :: term(), expected()}
          | {:delete, key :: String.t(), expected()}
          | {:get, key :: String.t()}
          | :clear
          | :count

  defstruct [:conn, :table, :channel_name, :monitored_pid]

  ## Public API

  @doc """
  Starts a temp state store for a channel under the dedicated DynamicSupervisor.

  `monitored_pid` is the channel process: when it goes down the store stops and the session
  (and therefore the temp table) is torn down. `db_conn` is the tenant's shared connection, used
  to read live capacity from the database before opening a new session.
  """
  @spec start(Tenant.t(), pid(), String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(%Tenant{} = tenant, monitored_pid, channel_name, db_conn) do
    with :ok <- within_capacity(db_conn) do
      opts = [tenant: tenant, monitored_pid: monitored_pid, channel_name: channel_name]
      DynamicSupervisor.start_child(__MODULE__.DynamicSupervisor, {__MODULE__, opts})
    end
  end

  defp within_capacity(db_conn) do
    case Postgrex.query(db_conn, @capacity_query, [@application_name]) do
      {:ok, %{rows: [[used, max_connections]]}} ->
        if used >= capacity_limit(max_connections), do: {:error, :too_many_state_stores}, else: :ok

      {:error, _} ->
        {:error, :cap_check_failed}
    end
  end

  defp capacity_limit(max_connections) do
    from_database = max(1, floor(max_connections * max_connection_fraction()))
    min(max_per_tenant(), from_database)
  end

  @doc "Absolute ceiling on live stores per tenant database, regardless of `max_connections`."
  @spec max_per_tenant() :: pos_integer()
  def max_per_tenant do
    Application.get_env(:realtime, :temp_state_store_max_per_tenant, @default_max_per_tenant)
  end

  @doc "Fraction of the tenant database's `max_connections` that temp state stores may use."
  @spec max_connection_fraction() :: float()
  def max_connection_fraction do
    Application.get_env(:realtime, :temp_state_store_max_connection_fraction, @default_max_connection_fraction)
  end

  @doc "Maximum byte size of a single (JSON-encoded) value."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes do
    Application.get_env(:realtime, :temp_state_store_max_value_bytes, @default_max_value_bytes)
  end

  @doc "Maximum number of keys a single store may hold."
  @spec max_keys() :: pos_integer()
  def max_keys do
    Application.get_env(:realtime, :temp_state_store_max_keys, @default_max_keys)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Upsert a key. Returns `{:ok, version}`."
  @spec put(pid(), String.t(), term()) :: {:ok, integer()} | {:error, term()}
  def put(pid, key, value), do: call(pid, {:put, key, value})

  @doc "Insert a key that must not exist yet. Returns `{:ok, version}` or `{:error, :already_exists}`."
  @spec insert(pid(), String.t(), term()) :: {:ok, integer()} | {:error, term()}
  def insert(pid, key, value), do: call(pid, {:insert, key, value})

  @doc """
  Update a key that must already exist. Returns `{:ok, version}` or `{:error, :not_found}`.

  Pass `expected` (the version last read) for an optimistic, compare-and-set update: it only
  applies when the current version matches, otherwise returns `{:error, {:version_mismatch, current}}`
  so the caller can re-read and retry. With `nil` (the default) it is a last-write-wins update.
  """
  @spec update(pid(), String.t(), term(), expected()) :: {:ok, version()} | {:error, term()}
  def update(pid, key, value, expected \\ nil), do: call(pid, {:update, key, value, expected})

  @doc """
  Delete a key. Returns `{:ok, :deleted}` or `{:error, :not_found}`.

  Pass `expected` for a compare-and-set delete: it only applies when the current version matches,
  otherwise returns `{:error, {:version_mismatch, current}}`.
  """
  @spec delete(pid(), String.t(), expected()) :: {:ok, :deleted} | {:error, term()}
  def delete(pid, key, expected \\ nil), do: call(pid, {:delete, key, expected})

  @doc "Read a key by primary key. Returns `{:ok, %{value, version, updated_at}}` or `{:error, :not_found}`."
  @spec get(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(pid, key), do: call(pid, {:get, key})

  @doc "Remove all rows via `TRUNCATE`."
  @spec clear(pid()) :: :ok | {:error, term()}
  def clear(pid), do: call(pid, :clear)

  @doc "Health-check count of rows in the temp table. Not for the hot path."
  @spec count(pid()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(pid), do: call(pid, :count)

  defp call(pid, command) do
    GenServer.call(pid, {:command, command})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    tenant = Keyword.fetch!(opts, :tenant)
    monitored_pid = Keyword.fetch!(opts, :monitored_pid)
    channel_name = Keyword.fetch!(opts, :channel_name)
    table = table_name(channel_name)

    Logger.metadata(external_id: tenant.external_id, project: tenant.external_id)

    case connect(tenant, table) do
      {:ok, conn} ->
        Process.monitor(monitored_pid)

        {:ok,
         %__MODULE__{
           conn: conn,
           table: table,
           channel_name: channel_name,
           monitored_pid: monitored_pid
         }}

      {:error, error} ->
        log_error("TempStateStoreConnectionError", error)
        {:stop, :normal}
    end
  end

  @impl true
  def handle_call({:command, command}, _from, state) do
    {:reply, run(command, state), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{monitored_pid: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    log_warning("TempStateStoreConnectionDown", reason)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    Process.exit(conn, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Commands

  defp run({:put, key, value}, %{conn: conn, table: table}) do
    sql = """
    INSERT INTO #{table} (key, value)
    SELECT $1, $2::jsonb
    WHERE (SELECT count(*) FROM #{table}) < $3
       OR EXISTS (SELECT 1 FROM #{table} WHERE key = $1)
    ON CONFLICT (key)
    DO UPDATE SET value = EXCLUDED.value,
                  version = #{table}.version + 1,
                  updated_at = clock_timestamp()
    RETURNING version
    """

    with {:ok, value} <- encode_and_validate(key, value),
         {:ok, result} <- query(conn, sql, [key, value, max_keys()]) do
      case result do
        %{rows: [[version]]} -> {:ok, version}
        %{num_rows: 0} -> {:error, :limit_reached}
      end
    end
  end

  defp run({:insert, key, value}, %{conn: conn, table: table}) do
    sql = """
    INSERT INTO #{table} (key, value)
    SELECT $1, $2::jsonb
    WHERE (SELECT count(*) FROM #{table}) < $3
       OR EXISTS (SELECT 1 FROM #{table} WHERE key = $1)
    RETURNING version
    """

    with {:ok, value} <- encode_and_validate(key, value) do
      case query(conn, sql, [key, value, max_keys()]) do
        {:ok, %{rows: [[version]]}} -> {:ok, version}
        {:ok, %{num_rows: 0}} -> {:error, :limit_reached}
        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> {:error, :already_exists}
        {:error, _} = error -> error
      end
    end
  end

  defp run({:update, key, value, expected}, %{conn: conn, table: table}) do
    {sql, params_tail} =
      case expected do
        nil ->
          {"UPDATE #{table} SET value = $2::jsonb, version = version + 1, updated_at = clock_timestamp() WHERE key = $1 RETURNING version",
           []}

        version ->
          {"UPDATE #{table} SET value = $2::jsonb, version = version + 1, updated_at = clock_timestamp() WHERE key = $1 AND version = $3 RETURNING version",
           [version]}
      end

    with {:ok, value} <- encode_and_validate(key, value) do
      case query(conn, sql, [key, value | params_tail]) do
        {:ok, %{rows: [[version]]}} -> {:ok, version}
        {:ok, %{num_rows: 0}} when is_nil(expected) -> {:error, :not_found}
        {:ok, %{num_rows: 0}} -> version_conflict(conn, table, key)
        {:error, _} = error -> error
      end
    end
  end

  defp run({:delete, key, expected}, %{conn: conn, table: table}) do
    {sql, params} =
      case expected do
        nil -> {"DELETE FROM #{table} WHERE key = $1", [key]}
        version -> {"DELETE FROM #{table} WHERE key = $1 AND version = $2", [key, version]}
      end

    case query(conn, sql, params) do
      {:ok, %{num_rows: 0}} when is_nil(expected) -> {:error, :not_found}
      {:ok, %{num_rows: 0}} -> version_conflict(conn, table, key)
      {:ok, _} -> {:ok, :deleted}
      {:error, _} = error -> error
    end
  end

  defp run({:get, key}, %{conn: conn, table: table}) do
    sql = "SELECT value, version, updated_at FROM #{table} WHERE key = $1"

    case query(conn, sql, [key]) do
      {:ok, %{rows: [[value, version, updated_at]]}} ->
        {:ok, %{value: decode(value), version: version, updated_at: updated_at}}

      {:ok, %{num_rows: 0}} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp run(:clear, %{conn: conn, table: table}) do
    case query(conn, "TRUNCATE #{table}", []) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp run(:count, %{conn: conn, table: table}) do
    case query(conn, "SELECT count(*) FROM #{table}", []) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, _} = error -> error
    end
  end

  ## Private

  defp query(conn, sql, params) do
    Postgrex.query(conn, sql, params)
  end

  defp encode_and_validate(key, value) do
    cond do
      byte_size(key) > @max_key_bytes ->
        {:error, :key_too_large}

      true ->
        with {:ok, encoded} <- encode(value) do
          if byte_size(encoded) > max_value_bytes(), do: {:error, :value_too_large}, else: {:ok, encoded}
        end
    end
  end

  defp encode(value) do
    {:ok, Jason.encode!(value)}
  rescue
    error -> {:error, error}
  end

  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp version_conflict(conn, table, key) do
    case query(conn, "SELECT version FROM #{table} WHERE key = $1", [key]) do
      {:ok, %{rows: [[version]]}} -> {:error, {:version_mismatch, version}}
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp connect(tenant, table) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, conn} <-
           Postgrex.start_link(
             hostname: settings.hostname,
             port: settings.port,
             database: settings.database,
             username: settings.username,
             password: settings.password,
             pool_size: 1,
             parameters: [application_name: @application_name],
             socket_options: settings.socket_options,
             ssl: settings.ssl,
             backoff_type: :stop,
             after_connect: {__MODULE__, :setup_session, [table]}
           ),
         {:ok, _} <- ready(conn) do
      {:ok, conn}
    end
  end

  defp ready(conn) do
    case Postgrex.query(conn, "SELECT 1", []) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        Process.exit(conn, :shutdown)
        error
    end
  end

  @doc false
  def setup_session(conn, table) do
    Enum.each(@session_settings, fn setting ->
      case Postgrex.query(conn, setting, []) do
        {:ok, _} -> :ok
        {:error, error} -> log_warning("TempStateStoreSettingSkipped", %{setting: setting, error: error})
      end
    end)

    Postgrex.query!(
      conn,
      """
      CREATE TEMP TABLE IF NOT EXISTS #{table} (
        key text PRIMARY KEY,
        value jsonb NOT NULL,
        version bigint NOT NULL DEFAULT 1,
        updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    :ok
  end

  @doc false
  def table_name(channel_name) do
    sanitized =
      channel_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.slice(0, 30)
      |> String.trim("_")

    hash = :crypto.hash(:sha256, channel_name) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "realtime_state_#{sanitized}_#{hash}"
  end
end
