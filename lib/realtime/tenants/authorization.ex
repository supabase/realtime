defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set permissions for a given connection.

  It will assign the a new key to a socket or a conn with the following:
  * read - a boolean indicating whether the connection has read permissions
  """
  require Logger
  defstruct [:channel_name, :headers, :jwt, :claims, :role]

  defmodule Permissions do
    defstruct read: false

    @type t :: %__MODULE__{
            :read => boolean()
          }
  end

  @type t :: %__MODULE__{
          :channel_name => binary() | nil,
          :claims => map(),
          :headers => keyword({binary(), binary()}),
          :jwt => map(),
          :role => binary()
        }
  @doc """
  Builds a new authorization params struct.
  """
  def build_authorization_params(%{
        channel_name: channel_name,
        headers: headers,
        jwt: jwt,
        claims: claims,
        role: role
      }) do
    %__MODULE__{
      channel_name: channel_name,
      headers: headers,
      jwt: jwt,
      claims: claims,
      role: role
    }
  end

  @spec get_authorizations(Phoenix.Socket.t() | Plug.Conn.t(), DBConnection.t(), __MODULE__.t()) ::
          {:ok, Phoenix.Socket.t() | Plug.Conn.t()} | {:error, :unauthorized}
  @doc """
  Runs validations based on RLS policies to set permissions for a given connection (either Phoenix.Socket or Plug.Conn).
  """
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

  defp get_permissions_for_connection(conn, params) do
    %__MODULE__{
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
          {:ok, %Permissions{read: false}}

        {:ok, _} ->
          {:ok, %Permissions{read: true}}

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          {:ok, %Permissions{read: false}}

        {:error, error} ->
          Logger.error("Error getting permissions for connection: #{inspect(error)}")
          {:error, error}
      end
    end)
  end
end
