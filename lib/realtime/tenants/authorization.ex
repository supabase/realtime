defmodule Realtime.Tenants.Authorization do
  alias Plug.Conn
  alias Phoenix.Socket

  require Logger

  def get_authorizations(%Socket{} = socket, db_conn, params) do
    with {:ok, {:ok, permissions}} <- get_permissions_for_connection(db_conn, params) do
      {:ok, Socket.assign(socket, :permissions, permissions)}
    else
      {:error, _} -> {:error, :unauthorized}
    end
  end

  def get_authorizations(%Conn{} = conn, db_conn, params) do
    with {:ok, {:ok, permissions}} <- get_permissions_for_connection(db_conn, params) do
      {:ok, Conn.assign(conn, :permissions, permissions)}
    else
      {:error, _} -> {:error, :unauthorized}
    end
  end

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
      Postgrex.query!(
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
