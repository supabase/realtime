defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set permissions for a given connection.

  It will assign the a new key to a socket or a conn with the following:
  * read - a boolean indicating whether the connection has read permissions
  """
  require Logger

  import Ecto.Query

  alias Realtime.Repo
  alias Realtime.Api.Channel

  defstruct [:channel, :headers, :jwt, :claims, :role]

  defmodule Permissions do
    defstruct read: false, write: false

    @type t :: %__MODULE__{
            :read => boolean(),
            :write => boolean()
          }
  end

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

  defp get_permissions_for_connection(conn, params) do
    Postgrex.transaction(conn, fn transaction_conn ->
      set_config(transaction_conn, params)
      permissions = %Permissions{}

      with {:ok, %{write: false} = permissions} <-
             check_write_permissions(transaction_conn, permissions, params),
           {:ok, permissions} <- check_read_permissions(transaction_conn, permissions) do
        {:ok, permissions}
      end
    end)
  end

  defp set_config(conn, params) do
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

  defp check_read_permissions(conn, permissions) do
    query = from(c in Channel, select: c.name)

    case Repo.all(conn, query, Channel, mode: :savepoint) do
      {:ok, channels} when channels != [] ->
        {:ok, %Permissions{permissions | read: true}}

      {:ok, _} ->
        {:ok, %Permissions{permissions | read: false}}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, %Permissions{permissions | read: false}}

      {:error, error} ->
        Logger.error("Error getting permissions for connection: #{inspect(error)}")
        {:error, error}
    end
  end

  defp check_write_permissions(_, permissions, %__MODULE__{channel: nil}) do
    {:ok, %Permissions{permissions | write: false}}
  end

  defp check_write_permissions(conn, permissions, %__MODULE__{channel: channel}) do
    changeset = Channel.check_changeset(channel, %{check: true})

    case Repo.update(conn, changeset, Channel, mode: :savepoint) do
      {:ok, %Channel{check: true} = channel} ->
        revert_changeset = Channel.check_changeset(channel, %{check: nil})
        {:ok, _} = Repo.update(conn, revert_changeset, Channel)
        {:ok, %Permissions{permissions | write: true, read: true}}

      {:ok, _} ->
        {:ok, %Permissions{permissions | write: false}}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, %Permissions{permissions | write: false}}

      {:error, :not_found} ->
        {:ok, %Permissions{permissions | write: false}}

      {:error, error} ->
        Logger.error("Error getting permissions for connection: #{inspect(error)}")
        {:error, error}
    end
  end
end
