defmodule RealtimeWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limits tenants.
  """
  import Plug.Conn

  require Logger

  alias Realtime.Api.Tenant

  def init(opts) do
    opts
  end

  def call(
        %{
          assigns: %{
            tenant: %Tenant{
              events_per_second_rolling: avg,
              events_per_second_now: current,
              max_events_per_second: max
            }
          }
        } = conn,
        _opts
      ) do
    remaining = Integer.to_string(abs(max - current))
    avg = Integer.to_string(trunc(avg))
    max = Integer.to_string(max)

    conn =
      conn
      |> put_resp_header("x-rate-rolling", avg)
      |> put_resp_header("x-rate-limit", max)
      |> put_resp_header("x-rate-limit-remaining", remaining)

    if avg > max do
      message = %{message: "Too many requests"}

      conn
      |> send_resp(429, message)
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts) do
    conn
  end
end
