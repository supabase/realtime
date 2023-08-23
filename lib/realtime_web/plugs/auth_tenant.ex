defmodule RealtimeWeb.AuthTenant do
  @moduledoc """
  Authorization plug to ensure that only authorized clients can connect to the their tenant's endpoints.
  """
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
         {:ok, _claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  def call(conn, _opts), do: unauthorized(conn)

  defp access_token(conn) do
    authorization = get_req_header(conn, "authorization")
    apikey = get_req_header(conn, "apikey")

    cond do
      authorization != [] && match?(["Bearer " <> _], authorization) ->
        ["Bearer " <> token] = authorization
        token

      apikey != [] ->
        hd(apikey)

      true ->
        nil
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> halt()
end
