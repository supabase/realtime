defmodule RealtimeWeb.Dashboard.TenantInfo.TenantDatabase do
  @moduledoc """
  Reads the tenant database for the Tenant Info dashboard page (`RealtimeWeb.Dashboard.TenantInfo`).

  Every read runs in an unlinked task that starts its own connection. The connection pool traps exits and
  stops when the process that started it exits. So the connection closes when the task returns, crashes or
  is killed on timeout, and none of that can take the dashboard down.
  """
  use Realtime.Logs

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database

  @application_name "realtime_dashboard_tenant_info"
  @statement_timeout 5_000
  @read_timeout 15_000

  @type result :: {:ok, term()} | {:error, String.t()}

  @doc """
  Connects to the tenant database and calls `read` with the connection. Returns what `read` returns, or
  `{:error, message}` when the tenant does not exist, the connection fails, or the read crashes or takes
  longer than #{@read_timeout} ms.
  """
  @spec read(Tenant.t() | String.t(), (DBConnection.conn() -> result())) :: result()
  def read(external_id, read) when is_binary(external_id) do
    case Api.get_tenant_by_external_id(external_id) do
      %Tenant{} = tenant -> read(tenant, read)
      nil -> {:error, "Tenant not found"}
    end
  end

  def read(%Tenant{} = tenant, read) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> connect_and_read(tenant, read) end)

    case Task.yield(task, @read_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> read_failed(reason)
      nil -> read_failed(:timeout)
    end
  end

  @doc """
  Calls `query` with the connection in a read-only transaction, where each statement times out after
  #{@statement_timeout} ms. Returns `{:ok, result}`, or `{:error, reason}` when the transaction fails. A
  query that raises `Postgrex.Error` or `DBConnection.ConnectionError` rolls the transaction back, and
  that exception is the reason.
  """
  @spec read_only(DBConnection.conn(), (DBConnection.conn() -> term())) :: {:ok, term()} | {:error, term()}
  def read_only(conn, query) do
    Postgrex.transaction(conn, fn conn ->
      Postgrex.query!(conn, "SET TRANSACTION READ ONLY", [])
      Postgrex.query!(conn, "SET LOCAL statement_timeout = #{@statement_timeout}", [])
      query.(conn)
    end)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  defp read_failed(reason) do
    log_warning("TenantInfoDatabaseFailed", reason)
    {:error, "Failed to read the tenant database: #{inspect(reason)}"}
  end

  defp connect_and_read(tenant, read) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, conn} <- Database.connect_db(settings) do
      read.(conn)
    else
      {:error, reason} ->
        log_warning("TenantInfoConnectFailed", reason)
        {:error, "Failed to connect to the tenant database: #{inspect(reason)}"}
    end
  end
end
