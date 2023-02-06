defmodule RealtimeWeb.Plugs.AssignTenant do
  @moduledoc """
  Picks out the tenant from the request and assigns it in the conn.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  import Realtime.Helpers, only: [get_external_id: 1]

  require Logger

  alias Realtime.Api
  alias Realtime.RateCounter
  alias Realtime.GenCounter
  alias Realtime.Api.Tenant

  def init(opts) do
    opts
  end

  def call(%Plug.Conn{host: host} = conn, _opts) do
    with {:ok, external_id} <- get_external_id(host),
         %Tenant{} = tenant <- Api.get_tenant_by_external_id(external_id) do
      tenant =
        tenant
        |> tap(&GenCounter.new({:plug, :requests, &1.external_id}))
        |> tap(&RateCounter.new({:plug, :requests, &1.external_id}, idle_shutdown: :infinity))
        |> tap(&GenCounter.add({:plug, :requests, &1.external_id}))
        |> Api.preload_counters()

      assign(conn, :tenant, tenant)
    else
      {:error, :tenant_not_found_in_host} ->
        error_response(conn, "Tenant not found in host")

      nil ->
        error_response(conn, "Tenant not found in database")

      _e ->
        error_response(conn, "Error assigning tenant")
    end
  end

  defp error_response(conn, message) do
    conn
    |> put_status(401)
    |> json(%{message: message})
    |> halt()
  end
end
