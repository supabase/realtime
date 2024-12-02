defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set policies for a given connection and
  creates a Realtime.Tenants.Policies struct with the accumulated results of the policies
  for a given user and a given channel context

  Each extension will have its own set of ways to check Policies against the Authorization context but we will create some setup data to be used by the policies.

  Check more information at Realtime.Tenants.Authorization.Policies
  """
  require Logger

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Api.Message
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization.Policies

  defstruct [:topic, :headers, :jwt, :claims, :role]

  @type t :: %__MODULE__{
          :topic => binary() | nil,
          :claims => map(),
          :headers => keyword({binary(), binary()}),
          :jwt => map(),
          :role => binary()
        }

  @doc """
  Builds a new authorization struct which will be used to retain the information required to check Policies.

  Requires a map with the following keys:
  * topic: The name of the channel being accessed taken from the request
  * headers: Request headers when the connection was made or WS was updated
  * jwt: JWT String
  * claims: JWT claims
  * role: JWT role
  """
  @spec build_authorization_params(map()) :: t()
  def build_authorization_params(map) do
    %__MODULE__{
      topic: Map.get(map, :topic),
      headers: Map.get(map, :headers),
      jwt: Map.get(map, :jwt),
      claims: Map.get(map, :claims),
      role: Map.get(map, :role)
    }
  end

  @doc """
  Runs validations based on RLS policies to set policies for a given connection (either Phoenix.Socket or Plug.Conn).
  """
  @spec get_authorizations(Phoenix.Socket.t() | Plug.Conn.t(), DBConnection.t(), __MODULE__.t()) ::
          {:ok, Phoenix.Socket.t() | Plug.Conn.t()} | {:error, any()}
  def get_authorizations(%Phoenix.Socket{} = socket, db_conn, authorization_context) do
    case get_authorizations(db_conn, authorization_context) do
      {:ok, %Policies{} = policies} -> {:ok, Phoenix.Socket.assign(socket, :policies, policies)}
      {:error, error} -> {:error, error}
    end
  end

  def get_authorizations(%Plug.Conn{} = conn, db_conn, authorization_context) do
    case get_authorizations(db_conn, authorization_context) do
      {:ok, %Policies{} = policies} -> {:ok, Plug.Conn.assign(conn, :policies, policies)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Runs validations based on RLS policies and returns the policies
  """
  @spec get_authorizations(DBConnection.t(), __MODULE__.t()) ::
          {:ok, %Policies{}} | {:error, any()}
  def get_authorizations(db_conn, authorization_context) do
    case get_policies_for_connection(db_conn, authorization_context) do
      {:ok, %Policies{} = policies} -> {:ok, policies}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Sets the current connection configuration with the following config values:
  * role: The role of the user
  * realtime.topic: The name of the channel being accessed
  * request.jwt.claim.role: The role of the user
  * request.jwt.claim.sub: The sub claim of the JWT token
  * request.jwt.claims: The claims of the JWT token
  * request.headers: The headers of the request
  """
  @spec set_conn_config(DBConnection.t(), t()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def set_conn_config(conn, authorization_context) do
    %__MODULE__{
      topic: topic,
      headers: headers,
      claims: claims,
      role: role
    } = authorization_context

    claims = Jason.encode!(claims)
    headers = headers |> Map.new() |> Jason.encode!()

    Postgrex.query(
      conn,
      """
      SELECT
       set_config('role', $1, true),
       set_config('realtime.topic', $2, true),
       set_config('request.jwt.claims', $3, true),
       set_config('request.headers', $4, true)
      """,
      [role, topic, claims, headers]
    )
  end

  defp get_policies_for_connection(conn, authorization_context) do
    Database.transaction(conn, fn transaction_conn ->
      messages = [
        Message.changeset(%Message{}, %{topic: authorization_context.topic, extension: :broadcast}),
        Message.changeset(%Message{}, %{topic: authorization_context.topic, extension: :presence})
      ]

      {:ok, messages} = Repo.insert_all_entries(transaction_conn, messages, Message)

      {[%{id: broadcast_id}], [%{id: presence_id}]} =
        Enum.split_with(messages, &(&1.extension == :broadcast))

      set_conn_config(transaction_conn, authorization_context)
      policies = %Policies{}

      policies =
        get_read_policy_for_connection_and_extension(
          transaction_conn,
          authorization_context,
          broadcast_id,
          presence_id,
          policies
        )

      policies =
        get_write_policy_for_connection_and_extension(
          transaction_conn,
          authorization_context,
          policies
        )

      Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])

      policies
    end)
  end

  import Ecto.Query

  defp get_read_policy_for_connection_and_extension(
         conn,
         authorization_context,
         broadcast_id,
         presence_id,
         policies
       ) do
    query =
      from(m in Message,
        where: [topic: ^authorization_context.topic],
        where: [extension: :broadcast, id: ^broadcast_id],
        or_where: [extension: :presence, id: ^presence_id]
      )

    {:ok, res} = Repo.all(conn, query, Message)
    can_presence? = Enum.any?(res, fn %{id: id} -> id == presence_id end)
    can_broadcast? = Enum.any?(res, fn %{id: id} -> id == broadcast_id end)

    policies
    |> Policies.update_policies(:presence, :read, can_presence?)
    |> Policies.update_policies(:broadcast, :read, can_broadcast?)
  end

  defp get_write_policy_for_connection_and_extension(
         conn,
         authorization_context,
         policies
       ) do
    broadcast_changeset =
      Message.changeset(%Message{}, %{topic: authorization_context.topic, extension: :broadcast})

    presence_changeset =
      Message.changeset(%Message{}, %{topic: authorization_context.topic, extension: :presence})

    broadcast_result = Repo.insert(conn, broadcast_changeset, Message, mode: :savepoint)
    presence_result = Repo.insert(conn, presence_changeset, Message, mode: :savepoint)

    policies
    |> Policies.update_policies(:presence, :write, match?({:ok, _}, presence_result))
    |> Policies.update_policies(:broadcast, :write, match?({:ok, _}, broadcast_result))
  end
end
