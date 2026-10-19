defmodule RealtimeWeb.Plugs.Parsers.OctetStream do
  @moduledoc """
  `Plug.Parsers` implementation for `application/octet-stream` request bodies.

  The raw binary body is placed in `conn.private[:realtime_binary_body]`
  instead of `conn.body_params`, so a request body can't fake it.

  Supports the same options as `Plug.Conn.read_body/2`: `:length`,
  `:read_length`, `:read_timeout`, and `:body_reader`. Defaults inherit from
  `Plug.Conn.read_body/2` (8 MB max length).
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts) do
    Keyword.pop(opts, :body_reader, {Plug.Conn, :read_body, []})
  end

  @impl true
  def parse(conn, "application", "octet-stream", _headers, {{mod, fun, args}, opts}) do
    case apply(mod, fun, [conn, opts | args]) do
      {:ok, body, conn} ->
        {:ok, %{}, Plug.Conn.put_private(conn, :realtime_binary_body, body)}

      {:more, _data, conn} ->
        {:error, :too_large, conn}

      {:error, :timeout} ->
        raise Plug.TimeoutError

      {:error, _} ->
        raise Plug.BadRequestError
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts) do
    {:next, conn}
  end
end
