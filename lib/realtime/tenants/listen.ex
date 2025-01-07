defmodule Realtime.Tenants.Listen do
  @moduledoc """
  Listen for Postgres notifications to identify issues with the functions that are being called in tenants database
  """
  use GenServer, restart: :transient
  require Logger
  alias Realtime.Logs
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.PostgresCdc
  alias Realtime.Registry.Unique

  defstruct tenant_id: nil, listen_conn: nil

  @cdc "postgres_cdc_rls"
  @topic "realtime:system"
  def start_link(%Tenant{} = tenant) do
    name = {:via, Registry, {Unique, {__MODULE__, :tenant_id, tenant.external_id}}}
    GenServer.start_link(__MODULE__, tenant, name: name)
  end

  def init(%Tenant{external_id: external_id} = tenant) do
    Logger.metadata(external_id: external_id, project: external_id)

    settings =
      tenant
      |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
      |> then(&Database.from_settings(&1, "realtime_listen", :rand_exp, true))
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
      |> Map.put(:sync_connect, true)
      |> Map.put(:auto_reconnect, false)
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

  def handle_info({:notification, _, _, @topic, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"function" => "realtime.send"} = parsed} when is_map_key(parsed, "error") ->
        Logs.log_error("FailedSendFromDatabase", parsed)

      {:error, _} ->
        Logs.log_error("FailedToParseDiagnosticMessage", payload)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
