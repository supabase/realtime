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
  alias Realtime.Helpers
  defstruct tenant_id: nil, listen_conn: nil

  @spec start(Realtime.Api.Tenant.t()) :: {:ok, pid()} | {:error, any()}
  def start(%Tenant{} = tenant) do
    supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Listen.DynamicSupervisor, self()}}
    spec = {__MODULE__, tenant}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, e} -> {:error, e}
    end
  end

  def start_link(%Tenant{} = tenant) do
    name = {:via, Registry, {Unique, {__MODULE__, :tenant_id, tenant.external_id}}}
    GenServer.start_link(__MODULE__, tenant, name: name)
  end

  @cdc "postgres_cdc_rls"
  @topic "realtime:broadcast"
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
      |> Map.put(:username, settings[:user])
      |> Map.put(:port, String.to_integer(settings[:port]))
      |> Map.put(:ssl, settings[:ssl_enforced])
      |> Map.put(:auto_reconnect, true)
      |> Map.put(:name, name)
      |> Enum.to_list()

    case Postgrex.Notifications.start_link(settings) do
      {:ok, conn} ->
        Postgrex.Notifications.listen(conn, @topic)
        Logger.info("Listening to notifications on topic #{@topic} for tenant database")

        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      {:error, {:already_started, conn}} ->
        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      e ->
        Helpers.log_error("UnableToListenToTenantDatabase", e)
        {:stop, e}
    end
  end

  def terminate(_, %{listen_conn: listen_conn}) do
    Postgrex.Notifications.unlisten(listen_conn, @topic)
  end

  def handle_info(
        {:notification, _, _, "realtime:broadcast", payload},
        %{tenant_id: tenant_id} = state
      ) do
    tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)

    content =
      case Jason.decode(payload) do
        {:ok, content} when is_list(content) -> {:ok, content}
        {:ok, content} -> {:ok, [content]}
        {:error, error} -> {:error, error}
      end

    with {:ok, content} <- content,
         :ok <- BatchBroadcast.broadcast(%{}, tenant, %{messages: content}, true) do
      :ok
    else
      %Ecto.Changeset{valid?: false, changes: %{messages: messages}} ->
        Helpers.log_error("UnableToBroadcastListenPayload", messages)

      {:error, error} ->
        Helpers.log_error("UnableToProcessListenPayload", error)
    end

    {:noreply, state}
  end
end
