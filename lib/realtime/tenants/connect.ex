defmodule Realtime.Tenants.Connect do
  use GenServer

  require Logger

  alias Realtime.Helpers
  alias Realtime.PostgresCdc

  @cdc "postgres_cdc_rls"

  @spec connection_status(binary()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connection_status(tenant_id) do
    case get_status(tenant_id) do
      :undefined ->
        :ok
        node = Realtime.Nodes.get_node_for_tenant_id(tenant_id)

        case :rpc.call(node, __MODULE__, :set_status, [tenant_id]) do
          :ok -> get_status(tenant_id)
          error -> error
        end

      {:ok, conn} ->
        {:ok, conn}

      _ ->
        {:error, :tenant_database_unavailable}
    end
  end

  def set_status(tenant_id) do
    :ok = GenServer.cast(__MODULE__, {:set_status, tenant_id})
    set_status_backoff(tenant_id)
  end

  def get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: conn}} when not is_nil(conn) -> {:ok, conn}
      error -> error
    end
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state), do: {:ok, state, {:continue, :setup_syn}}

  def handle_continue(:setup_syn, state) do
    :ok = :syn.add_node_to_scopes([__MODULE__])
    {:noreply, state}
  end

  def handle_cast({:set_status, tenant_id}, state) do
    res = check_tenant_connection(tenant_id)
    :ok = update_syn_with_conn_check(res, tenant_id)
    {:noreply, state}
  end

  defp set_status_backoff(tenant_id, times \\ 5, backoff \\ 500)
  defp set_status_backoff(_, 0, _), do: {:error, :tenant_database_unavailable}

  defp set_status_backoff(tenant_id, times, backoff) do
    case get_status(tenant_id) do
      :undefined ->
        :timer.sleep(backoff)
        set_status_backoff(tenant_id, times - 1, backoff)

      _ ->
        :ok
    end
  end

  defp update_syn_with_conn_check(res, tenant_id) do
    case res do
      {:ok, conn} -> :syn.register(__MODULE__, tenant_id, self(), %{conn: conn})
      {:error, _} -> :syn.register(__MODULE__, tenant_id, self(), %{conn: nil})
    end
  end

  defp check_tenant_connection(tenant_id) do
    tenant = Realtime.Tenants.get_tenant_by_external_id(tenant_id)

    if is_nil(tenant) do
      {:error, :tenant_not_found}
    else
      tenant
      |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
      |> then(fn settings ->
        ssl_enforced = Helpers.default_ssl_param(settings)

        host = settings["db_host"]
        port = settings["db_port"]
        name = settings["db_name"]
        user = settings["db_user"]
        password = settings["db_password"]
        socket_opts = settings["db_socket_opts"]

        opts = %{
          host: host,
          port: port,
          name: name,
          user: user,
          pass: password,
          socket_opts: socket_opts,
          pool: 1,
          queue_target: 1000,
          ssl_enforced: ssl_enforced
        }

        with {:ok, conn} <- Helpers.connect_db(opts) do
          case Postgrex.query(conn, "SELECT 1", []) do
            {:ok, _} ->
              {:ok, conn}

            {:error, e} ->
              Logger.error("Error connecting to tenant database: #{inspect(e)}")
              {:error, :tenant_database_unavailable}
          end
        end
      end)
    end
  end
end
