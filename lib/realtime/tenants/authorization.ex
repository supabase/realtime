defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set permissions for a given connection and
  creates a Realtime.Tenants.Permissions struct with the accumulated results of the permissions for a given user and a given channel context
  """
  require Logger

  alias Realtime.Api.Channel
  alias Realtime.Tenants.Authorization.Permissions
  alias Realtime.Tenants.Authorization.Permissions.ChannelPermissions

  defstruct [:channel, :headers, :jwt, :claims, :role]

  @type t :: %__MODULE__{
          :channel => Channel.t() | nil,
          :claims => map(),
          :headers => keyword({binary(), binary()}),
          :jwt => map(),
          :role => binary()
        }

  @doc """
  Builds a new authorization params struct.
  """
  def build_authorization_params(%{
        channel: channel,
        headers: headers,
        jwt: jwt,
        claims: claims,
        role: role
      }) do
    %__MODULE__{
      channel: channel,
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

  def set_conn_config(conn, params) do
    %__MODULE__{
      channel: channel,
      headers: headers,
      jwt: jwt,
      claims: claims,
      role: role
    } = params

    sub = Map.get(claims, :sub)
    claims = Jason.encode!(claims)
    headers = headers |> Map.new() |> Jason.encode!()
    channel_name = if channel, do: channel.name, else: nil

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
  end

  @permission_mods [ChannelPermissions]
  defp get_permissions_for_connection(conn, params) do
    Postgrex.transaction(conn, fn transaction_conn ->
      set_conn_config(transaction_conn, params)

      permissions =
        Enum.reduce(@permission_mods, %Permissions{}, fn permission_mod, permissions ->
          permission_mod.build_permissions(permissions)

          with {:ok, permissions} <-
                 permission_mod.check_write_permissions(
                   transaction_conn,
                   permissions,
                   params
                 ),
               {:ok, permissions} <-
                 permission_mod.check_read_permissions(transaction_conn, permissions) do
            permissions
          end
        end)

      {:ok, permissions}
    end)
  end
end
