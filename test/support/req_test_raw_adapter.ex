defmodule Realtime.ReqTestRawAdapter do
  @moduledoc """
  Req adapter that dispatches to a `Req.Test` stub without touching the request body.

  Since Req 0.6, the built-in `:plug` adapter (`Req.Steps.run_plug/1`) transparently
  gunzips any request body sent with a `content-encoding` header and drops that header
  before building the `Plug.Conn` handed to the plug/stub. That makes it impossible for
  a stub to assert that a request was actually compressed on the wire, which is exactly
  what the MetricsPusher tests need. This adapter mirrors what `run_plug/1` used to do
  before that change: build the `Plug.Conn` straight from the raw request body/headers
  and dispatch to the named `Req.Test` stub.
  """

  @spec call(Req.Request.t(), term()) :: {Req.Request.t(), Req.Response.t()}
  def call(request, name) do
    body = IO.iodata_to_binary(request.body || "")
    headers = for {header, values} <- request.headers, value <- values, do: {header, value}

    conn =
      %Plug.Conn{}
      |> Req.Test.Adapter.conn(request.method, request.url, body)
      |> Map.replace!(:req_headers, headers)
      |> Req.Test.call(Req.Test.init(name))

    response = Req.Response.new(status: conn.status, headers: conn.resp_headers, body: conn.resp_body)

    {request, response}
  end
end
