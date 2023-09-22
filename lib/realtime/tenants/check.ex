defmodule Realtime.Tenants.Check do
  use GenServer
  require Logger
  alias Realtime.PostgresCdc
  alias Realtime.Tenants
  alias Realtime.Helpers

  defstruct [:tenant_id]

  @type t :: %__MODULE__{tenant_id: String.t()}

  def start_link(%__MODULE__{tenant_id: tenant_id} = opts),
    do: GenServer.start_link(__MODULE__, %{opts: opts}, name: process_name(tenant_id))

  def init(state), do: {:ok, state, {:continue, :check_tenant}}

  def connection_status(tenant_id), do: GenServer.call(process_name(tenant_id), :check_status)

  def handle_call(:check_status, _from, %{opts: %{tenant_id: _tenant_id}} = state) do
    {:reply, :ok, state}
  end

  def handle_continue(:check_tenant, %{opts: %{tenant_id: tenant_id}} = state) do
    with %{extensions: extensions} = tenant <- Tenants.get_tenant_by_external_id(tenant_id),
         region <- get_region(extensions),
         tenant_region <- PostgresCdc.platform_region_translator(region),
         app_region <- Application.get_env(:realtime, :region) do
      if tenant_region == app_region do
        Process.send_after(self(), :check_status, 1_000)
        {:noreply, state}
      else
        {:noreply, Map.put(state, :tenant, tenant), {:continue, :setup_syn}}
      end
    else
      nil ->
        Logger.error("Unable to initialize checker, tenant not found: #{tenant_id}")
        {:stop, :tenant_not_found, state}

      error ->
        Logger.error("Unable to initialize checker due to error: #{inspect(error)}")
        {:stop, error, state}
    end
  end

  def handle_continue(:setup_syn, state) do
    :ok = :syn.add_node_to_scopes([__MODULE__])
    Process.send_after(self(), :set_status, 1_000)
    {:noreply, state}
  end

  def handle_info(:check_status, state) do
    {:noreply, state}
  end

  def handle_info(:set_status, state) do
    case check_tenant_connection(state.tenant.extensions) do
      :ok -> nil
      {:error, _} -> nil
    end

    Process.send_after(self(), :set_status, 1_000)
    {:noreply, state}
  end

  defp get_region(extensions) do
    extensions
    |> Enum.map(fn %{settings: %{"region" => region}} -> region end)
    |> Enum.uniq()
    |> hd()
  end

  defp check_tenant_connection(extensions) do
    extensions
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

      with {:ok, conn} <- Helpers.connect_db(opts),
           {:ok, _} <- Postgrex.query(conn, "SELECT 1", []) do
        Process.exit(conn, :normal)
        :ok
      end
    end)
    |> Enum.any?(fn res -> res == :ok end)
    |> then(fn
      true -> :ok
      false -> {:error, :tenant_database_unavailable}
    end)
  end

  defp process_name(tenant_id), do: {:via, Registry, {Realtime.Registry.Tenant, tenant_id}}
end
