defmodule RealtimeWeb.RlsAuthorization do
  @moduledoc """
  Authorization plug to ensure with RLS rules that a user can access a resource using the Realtime.Tenants.Authorization module.
  """
  require Logger

  import Plug.Conn

  alias Realtime.Channels
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.FallbackController
  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{tenant: tenant}} = conn, _opts) do
    params = %{
      headers: conn.req_headers,
      jwt: conn.assigns.jwt,
      claims: conn.assigns.claims,
      role: conn.assigns.role
    }

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant.external_id),
         params <- set_channel_params_for_authorization_check(conn, db_conn, params),
         params <- Authorization.build_authorization_params(params),
         {:ok, conn} <- Authorization.get_authorizations(conn, db_conn, params) do
      conn
    else
      error ->
        conn |> FallbackController.call(error) |> halt()
    end
  end

  def call(conn, _opts), do: unauthorized(conn) |> halt()

  defp set_channel_params_for_authorization_check(conn, db_conn, params) do
    %{path_params: path_params, body_params: body_params} = conn

    params =
      cond do
        Map.get(body_params, "name", nil) ->
          name = Map.fetch!(body_params, "name")
          Map.put(params, :channel_name, name)

        true ->
          params
      end

    with {:ok, name} <- Map.fetch(path_params, "name"),
         {:ok, channel} <- Channels.get_channel_by_name(name, db_conn) do
      params
      |> Map.put(:channel, channel)
      |> Map.put(:channel_name, channel.name)
    else
      _ -> Map.put(params, :channel, nil)
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
