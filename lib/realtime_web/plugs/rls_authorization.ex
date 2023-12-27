defmodule RealtimeWeb.RlsAuthorization do
  @moduledoc """
  Authorization plug to ensure with RLS rules that a user can access a resource using the Realtime.Tenants.Authorization module.
  """
  require Logger

  import Plug.Conn

  alias Realtime.Channels
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{tenant: tenant}} = conn, _opts) do
    params = %{
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         params <- set_channel_name(conn, db_conn, params),
         {:ok, conn} <- Authorization.get_authorizations(conn, db_conn, params) do
      conn
    else
      error ->
        Logger.error("Error authorizing connection: #{inspect(error)}")
        unauthorized(conn)
    end
  end

  def call(conn, _opts), do: unauthorized(conn) |> halt()

  defp set_channel_name(%{path_params: %{"id" => id}}, db_conn, params) do
    case Channels.get_channel_by_id(id, db_conn) do
      {:ok, channel} -> Map.put(params, :channel_name, channel.name)
      _ -> Map.put(params, :channel_name, nil)
    end
  end

  defp set_channel_name(_, _, params), do: Map.put(params, :channel_name, nil)
  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
