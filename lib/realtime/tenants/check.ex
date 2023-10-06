defmodule Realtime.Tenants.Check do
  use GenServer

  require Logger

  alias Realtime.Helpers

  def connection_status(tenant_id) do
    case get_status(tenant_id) do
      :undefined ->
        :ok
        node = Realtime.Nodes.get_node_for_tenant_id(tenant_id)

        case :rpc.call(node, __MODULE__, :set_status, [tenant_id]) do
          :ok ->
            case get_status(tenant_id) do
              {_, %{healthy?: true}} -> :ok
              {_, res} -> res
            end

          error ->
            error
        end

      {_, %{healthy?: true}} ->
        :ok

      _ ->
        {:error, :tenant_database_unavailable}
    end
  end

  def set_status(tenant_id) do
    __MODULE__
    |> Process.whereis()
    |> Process.send({:set_status, tenant_id}, [])

    set_status_backoff(tenant_id)
  end

  def get_status(tenant_id) do
    :syn.lookup(__MODULE__, tenant_id)
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state), do: {:ok, state, {:continue, :setup_syn}}

  def handle_continue(:setup_syn, state) do
    :ok = :syn.add_node_to_scopes([__MODULE__])
    {:noreply, state}
  end

  def handle_info({:set_status, tenant_id}, state) do
    res = check_tenant_connection(tenant_id)
    :ok = update_syn_with_conn_check(res, tenant_id)
    Process.send_after(self(), {:set_status, tenant_id}, 500)
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
      :ok -> :syn.register(__MODULE__, tenant_id, self(), %{healthy?: true})
      {:error, _} -> :syn.register(__MODULE__, tenant_id, self(), %{healthy?: false})
    end
  end

  defp check_tenant_connection(tenant_id) do
    tenant = Realtime.Tenants.get_tenant_by_external_id(tenant_id)

    if is_nil(tenant) do
      {:error, :tenant_not_found}
    else
      tenant
      |> then(& &1.extensions)
      |> Enum.map(fn %{settings: settings} ->
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
            {:ok, _} -> {:ok, conn}
            {:error, _} -> {:error, conn}
          end
        end
      end)
      # This makes the connection fail
      |> tap(fn res ->
        Enum.each(res, fn {_, conn} -> Process.exit(conn, :normal) end)
      end)
      |> Enum.any?(fn res -> elem(res, 0) == :ok end)
      |> then(fn
        true -> :ok
        false -> {:error, :tenant_database_unavailable}
      end)
    end
  end
end
