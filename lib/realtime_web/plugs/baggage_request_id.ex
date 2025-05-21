defmodule RealtimeWeb.Plugs.BaggageRequestId do
  @moduledoc """
  Populates request ID based on trace baggage.
  It looks for the specified `baggage_key` (default to 'request-id').

  Otherwise generates a request ID using `Plug.RequestId`
  """

  def baggage_key, do: Application.get_env(:realtime, :request_id_baggage_key, "request-id")

  require Logger
  alias Plug.Conn
  @behaviour Plug

  @impl true
  @doc false
  def init(opts) do
    Keyword.get(opts, :baggage_key, "request-id")
  end

  @impl true
  @doc false
  @spec call(Conn.t(), String.t()) :: Conn.t()
  def call(conn, baggage_key) do
    :otel_propagator_text_map.extract(conn.req_headers)

    with %{^baggage_key => {request_id, _}} <- :otel_baggage.get_all(),
         true <- valid_request_id?(request_id) do
      Logger.metadata(request_id: request_id)
      Conn.put_resp_header(conn, "x-request-id", request_id)
    else
      _ ->
        opts = Plug.RequestId.init([])
        Plug.RequestId.call(conn, opts)
    end
  end

  defp valid_request_id?(s), do: byte_size(s) in 10..200
end
