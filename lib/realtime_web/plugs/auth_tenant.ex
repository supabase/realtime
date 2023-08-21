defmodule RealtimeWeb.AuthTenant do
  import Plug.Conn
  import Realtime.Helpers

  alias Realtime.Api.Tenant
  alias RealtimeWeb.ChannelsAuthorization

  def init(opts), do: opts

  def call(%{assigns: %{tenant: tenant}} = conn, _opts) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    with %Tenant{jwt_secret: jwt_secret} <- tenant,
         token when is_binary(token) <- access_token(conn),
         jwt_secret_dec <- decrypt!(jwt_secret, secure_key),
         {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  def call(conn, _opts), do: unauthorized(conn)

  defp access_token(conn) do
    case get_req_header(conn, "x-api-key") do
      [] -> fetch_api_key_param(conn)
      [token] -> token
      _ -> nil
    end
  end

  defp fetch_api_key_param(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> then(& &1.query_params)
    |> Map.get("apikey")
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
