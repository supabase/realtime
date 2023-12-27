defmodule RealtimeWeb.RlsAuthorization do
  @moduledoc """
  Authorization plug to ensure with RLS rules that a user can access a resource.
  """
  require Logger

  import Plug.Conn

  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect
  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{tenant: tenant}} = conn, _opts) do
    params = %{
      channel_name: nil,
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         {:ok, conn} <- Authorization.get_authorizations(conn, db_conn, params) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  def call(conn, _opts), do: unauthorized(conn) |> halt()
  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
