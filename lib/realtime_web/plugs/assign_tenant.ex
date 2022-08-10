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

  def call(conn, _opts) do
    uri = request_url(conn) |> URI.parse()

    tenant =
      case String.split(uri.host, ".") do
        # Should really get this from something more predictible
        [external_id, _] ->
          Api.get_tenant_by_external_id(external_id)
          |> tap(&GenCounter.new(&1.external_id))
          |> tap(&RateCounter.new(&1.external_id))
          |> tap(&GenCounter.add(&1.external_id))
          |> Api.preload_rate_counter()

        _ ->
          nil
      end

    if tenant do
      assign(conn, :tenant, tenant)
    else
      Logger.warn("Tenant not found in request url: #{inspect(uri)}")

      conn
    end
  end
end
