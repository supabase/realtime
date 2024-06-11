defmodule RealtimeWeb.AuthTenant do
  @moduledoc """
  Authorization plug to ensure that only authorized clients can connect to the their tenant's endpoints.
  """
  require Logger

  import Plug.Conn

  alias Realtime.Api.Tenant
  alias Realtime.Crypto

  alias RealtimeWeb.ChannelsAuthorization

  def init(opts), do: opts

  def call(%{assigns: %{tenant: tenant}} = conn, _opts) do
    with %Tenant{jwt_secret: jwt_secret, jwt_jwks: jwt_jwks} <- tenant,
         token when is_binary(token) <- access_token(conn),
         jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
         {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec, jwt_jwks) do
      Logger.metadata(external_id: tenant.external_id, project: tenant.external_id)

      conn
      |> assign(:claims, claims)
      |> assign(:jwt, token)
      |> assign(:role, claims["role"])
    else
      _ ->
        conn
        |> unauthorized()
        |> halt()
    end
  end

  def call(conn, _opts), do: unauthorized(conn)

  defp access_token(conn) do
    authorization = get_req_header(conn, "authorization")
    apikey = get_req_header(conn, "apikey")

    authorization =
      case authorization do
        [] ->
          nil

        [value | _] ->
          [bearer, token] = value |> String.split(" ")
          bearer = String.downcase(bearer)
          if bearer == "bearer", do: token
      end

    apikey =
      case apikey do
        [] -> nil
        [value | _] -> value
      end

    cond do
      authorization -> authorization
      apikey -> apikey
      true -> nil
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
