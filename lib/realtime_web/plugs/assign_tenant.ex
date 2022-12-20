defmodule RealtimeWeb.Plugs.AssignTenant do
  @moduledoc """
  Picks out the tenant from the request and assigns it in the conn.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

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
        |> tap(&GenCounter.new({:limit, :all, &1.external_id}))
        |> tap(&RateCounter.new({:limit, :all, &1.external_id}, idle_shutdown: :infinity))
        |> tap(&GenCounter.add({:limit, :all, &1.external_id}))
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

  defp get_external_id(host) do
    case String.split(host, ".") do
      [] -> {:error, :tenant_not_found_in_host}
      [_] -> {:error, :tenant_not_found_in_host}
      [_, _] -> {:error, :tenant_not_found_in_host}
      ["www", _, _] -> {:error, :tenant_not_found_in_host}
      list -> {:ok, Enum.at(list, 0)}
    end
  end

  defp error_response(conn, message) do
    conn
    |> put_status(401)
    |> json(%{message: message})
    |> halt()
  end
end
