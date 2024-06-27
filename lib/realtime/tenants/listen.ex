defmodule Realtime.Tenants.Listen do
  @moduledoc """
  Creates a listener for tenant NOTIFY postgres commands.
  """
  use GenServer, restart: :transient
  require Logger

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.PostgresCdc
  alias Realtime.Registry.Unique
  alias Realtime.Tenants
  alias Realtime.Tenants.BatchBroadcast

  defstruct tenant_id: nil, listen_conn: nil

  @cdc "postgres_cdc_rls"
  @topic "realtime:broadcast"
  def start_link(%Tenant{} = tenant) do
    name = {:via, Registry, {Unique, {__MODULE__, :tenant_id, tenant.external_id}}}
    GenServer.start_link(__MODULE__, tenant, name: name)
  end

  def init(%Tenant{} = tenant) do
    settings =
      tenant
      |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
      |> then(fn settings ->
        Database.from_settings(settings, "realtime_listen", :rand_exp, true)
      end)
      |> Map.from_struct()

    name =
      {:via, Registry,
       {Realtime.Registry.Unique, {Postgrex.Notifications, :tenant_id, tenant.external_id}}}

    settings =
      settings
      |> Map.put(:hostname, settings[:host])
      |> Map.put(:database, settings[:name])
      |> Map.put(:password, settings[:pass])
      |> Map.put(:username, "postgres")
      |> Map.put(:port, String.to_integer(settings[:port]))
      |> Map.put(:ssl, settings[:ssl_enforced])
      |> Map.put(:auto_reconnect, true)
      |> Map.put(:name, name)
      |> Enum.to_list()

    Logger.info("Listening for notifications on #{@topic}")

    case Postgrex.Notifications.start_link(settings) do
      {:ok, conn} ->
        Postgrex.Notifications.listen!(conn, @topic)
        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      {:error, {:already_started, conn}} ->
        Postgrex.Notifications.listen!(conn, @topic)
        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      {:error, reason} ->
        {:stop, reason}
    end
  catch
    e -> {:stop, e}
  end

  @spec start(Realtime.Api.Tenant.t()) :: {:ok, pid()} | {:error, any()}
  def start(%Tenant{} = tenant) do
    supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Listen.DynamicSupervisor, self()}}
    spec = {__MODULE__, tenant}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> {:error, error}
    end
  catch
    e -> {:error, e}
  end

  def handle_info(
        {:notification, _, _, "realtime:broadcast", payload},
        %{tenant_id: tenant_id} = state
      ) do
    tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)

    case Jason.decode(payload) do
      {:ok, content} when is_list(content) ->
        BatchBroadcast.broadcast(%{}, tenant, %{messages: content}, true)

      {:ok, content} ->
        BatchBroadcast.broadcast(%{}, tenant, %{messages: [content]}, true)

      {:error, _} ->
        Logger.error("Error decoding payload")
    end

    {:noreply, state}
  end
end