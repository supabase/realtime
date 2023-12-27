defmodule Realtime.Tenants.Authorization do
  require Logger

  @type params :: %{
          :channel_name => binary() | nil,
          :claims => map(),
          :headers => keyword({binary(), binary()}),
          :jwt => map(),
          :role => binary()
        }

  @spec get_authorizations(Phoenix.Socket.t() | Plug.Conn.t(), DBConnection.t(), params()) ::
          {:ok, Phoenix.Socket.t() | Plug.Conn.t()} | {:error, :unauthorized}
  def get_authorizations(%Phoenix.Socket{} = socket, db_conn, params) do
    case get_permissions_for_connection(db_conn, params) do
      {:ok, permissions} -> {:ok, Phoenix.Socket.assign(socket, :permissions, permissions)}
      _ -> {:error, :unauthorized}
    end
  end

  def get_authorizations(%Plug.Conn{} = conn, db_conn, params) do
    case get_permissions_for_connection(db_conn, params) do
      {:ok, permissions} -> {:ok, Plug.Conn.assign(conn, :permissions, permissions)}
      _ -> {:error, :unauthorized}
    end
  end

  @spec get_permissions_for_connection(DBConnection.conn(), map()) ::
          {:ok, map()} | {:error, any()}
  defp get_permissions_for_connection(conn, params) do
    %{
      channel_name: channel_name,
      headers: headers,
      jwt: jwt,
      claims: claims,
      role: role
    } = params

    sub = Map.get(claims, :sub)
    claims = Jason.encode!(claims)
    headers = headers |> Map.new() |> Jason.encode!()

    Postgrex.transaction(conn, fn conn ->
      Postgrex.query(
        conn,
        """
        SELECT
         set_config('role', $1, true),
         set_config('realtime.channel_name', $2, true),
         set_config('request.jwt.claim.role', $3, true),
         set_config('request.jwt', $4, true),
         set_config('request.jwt.claim.sub', $5, true),
         set_config('request.jwt.claims', $6, true),
         set_config('request.headers', $7, true)
        """,
        [role, channel_name, role, jwt, sub, claims, headers]
      )

      case Postgrex.query(conn, "SELECT name from realtime.channels", [], mode: :savepoint) do
        {:ok, %{num_rows: 0}} ->
          {:ok, %{read: false}}

        {:ok, _} ->
          {:ok, %{read: true}}

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          {:ok, %{read: false}}

        {:error, error} ->
          Logger.error("Error getting permissions for connection: #{inspect(error)}")
          {:error, error}
      end
    end)
  end
end
