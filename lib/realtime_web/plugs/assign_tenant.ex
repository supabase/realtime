defmodule RealtimeWeb.Plugs.AssignTenant do
  @moduledoc """
  Picks out the tenant from the request and assigns it in the conn.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants

  def init(opts) do
    opts
  end

  def call(%Plug.Conn{host: host} = conn, _opts) do
    with {:ok, external_id} <- Database.get_external_id(host),
         %Tenant{} = tenant <- Api.get_tenant_by_external_id(external_id) do
      Logger.metadata(external_id: external_id, project: external_id)
      OpenTelemetry.Tracer.set_attributes(external_id: external_id)

      tenant =
        tenant
        |> tap(&initialize_counters/1)
        |> tap(&GenCounter.add(Tenants.requests_per_second_key(&1)))
        |> Api.preload_counters()

      assign(conn, :tenant, tenant)
    else
      nil -> error_response(conn, "Tenant not found in database")
    end
  end

  defp error_response(conn, message) do
    conn
    |> put_status(401)
    |> json(%{message: message})
    |> halt()
  end

  defp initialize_counters(tenant) do
    GenCounter.new(Tenants.requests_per_second_key(tenant))
    GenCounter.new(Tenants.events_per_second_key(tenant))
    RateCounter.new(Tenants.requests_per_second_key(tenant), idle_shutdown: :infinity)
    RateCounter.new(Tenants.events_per_second_key(tenant), idle_shutdown: :infinity)
  end
end
