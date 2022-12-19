defmodule RealtimeWeb.Plugs.AssignTenant do
  @moduledoc """
  Picks out the tenant from the request and assigns it in the conn.
  """
  import Plug.Conn

  require Logger

  alias Realtime.Api
  alias Realtime.RateCounter
  alias Realtime.GenCounter

  def init(opts) do
    opts
  end

  def call(%Plug.Conn{host: host} = conn, _opts) do
    {:ok, external_id} = get_external_id(host)

    tenant =
      Api.get_tenant_by_external_id(external_id)
      |> tap(&GenCounter.new({:limit, :all, &1.external_id}))
      |> tap(&RateCounter.new({:limit, :all, &1.external_id}, idle_shutdown: :infinity))
      |> tap(&GenCounter.add({:limit, :all, &1.external_id}))
      |> Api.preload_counters()

    assign(conn, :tenant, tenant)
  end

  defp get_external_id(host) do
    case String.split(host, ".") do
      [] -> {:error, :tenant_not_found_in_host}
      [_] -> {:error, :tenant_not_found_in_host}
      list -> {:ok, Enum.at(list, 0)}
    end
  end
end
