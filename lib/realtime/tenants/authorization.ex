defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set policies for a given connection and
  creates a Realtime.Tenants.Policies struct with the accumulated results of the policies
  for a given user and a given channel context

  Each extension will have its own set of ways to check Policies against the Authorization context but we will create some setup data to be used by the policies.

  Check more information at Realtime.Tenants.Authorization.Policies
  """
  require Logger
  import Ecto.Query

  alias Phoenix.Socket
  alias Plug.Conn
  alias Realtime.Api.Message
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization.Policies
  alias DBConnection.ConnectionError
  defstruct [:tenant_id, :topic, :headers, :jwt, :claims, :role]

  @type t :: %__MODULE__{
          :tenant_id => binary() | nil,
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
      tenant_id: Map.get(map, :tenant_id),
      topic: Map.get(map, :topic),
      headers: Map.get(map, :headers),
      jwt: Map.get(map, :jwt),
      claims: Map.get(map, :claims),
      role: Map.get(map, :role)
    }
  end

  @doc """
  Runs validations based on RLS policies to set policies for read policies a given connection (either Phoenix.Socket or Plug.Conn).
  """
  @spec get_read_authorizations(Socket.t() | Conn.t(), pid(), __MODULE__.t()) ::
          {:ok, Socket.t() | Conn.t()} | {:error, any()} | {:error, :rls_policy_error, any()}

  def get_read_authorizations(%Socket{} = socket, db_conn, authorization_context) do
    policies = Map.get(socket.assigns, :policies) || %Policies{}

    case get_read_policies_for_connection(db_conn, authorization_context, policies) do
      {:ok, %Policies{} = policies} -> {:ok, Socket.assign(socket, :policies, policies)}
      {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, :rls_policy_error, error}
      {:error, %ConnectionError{reason: :queue_timeout}} -> {:error, :increase_connection_pool}
      {:error, error} -> {:error, error}
    end
  end

  def get_read_authorizations(%Conn{} = conn, db_conn, authorization_context) do
    policies = Map.get(conn.assigns, :policies) || %Policies{}

    case get_read_policies_for_connection(db_conn, authorization_context, policies) do
      {:ok, %Policies{} = policies} -> {:ok, Conn.assign(conn, :policies, policies)}
      {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, :rls_policy_error, error}
      {:error, %ConnectionError{reason: :queue_timeout}} -> {:error, :increase_connection_pool}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Runs validations based on RLS policies to set policies for read policies a given connection (either Phoenix.Socket or Conn).
  """
  @spec get_write_authorizations(Socket.t() | Conn.t() | pid(), pid(), __MODULE__.t()) ::
          {:ok, Socket.t() | Conn.t() | Policies.t()}
          | {:error, any()}
          | {:error, :rls_policy_error, any()}

  def get_write_authorizations(
        %Socket{} = socket,
        db_conn,
        authorization_context
      ) do
    policies = Map.get(socket.assigns, :policies) || %Policies{}

    case get_write_policies_for_connection(db_conn, authorization_context, policies) do
      {:ok, %Policies{} = policies} -> {:ok, Socket.assign(socket, :policies, policies)}
      {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, :rls_policy_error, error}
      {:error, %ConnectionError{reason: :queue_timeout}} -> {:error, :increase_connection_pool}
      {:error, error} -> {:error, error}
    end
  end

  def get_write_authorizations(%Conn{} = conn, db_conn, authorization_context) do
    policies = Map.get(conn.assigns, :policies) || %Policies{}

    case get_write_policies_for_connection(db_conn, authorization_context, policies) do
      {:ok, %Policies{} = policies} -> {:ok, Conn.assign(conn, :policies, policies)}
      {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, :rls_policy_error, error}
      {:error, %ConnectionError{reason: :queue_timeout}} -> {:error, :increase_connection_pool}
      {:error, error} -> {:error, error}
    end
  end

  def get_write_authorizations(db_conn, db_conn, authorization_context) when is_pid(db_conn) do
    case get_write_policies_for_connection(db_conn, authorization_context, %Policies{}) do
      {:ok, %Policies{} = policies} -> {:ok, policies}
      {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, :rls_policy_error, error}
      {:error, %ConnectionError{reason: :queue_timeout}} -> {:error, :increase_connection_pool}
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

  defp get_read_policies_for_connection(conn, authorization_context, policies) do
    opts = [telemetry: [:realtime, :tenants, :read_authorization_check], tenant_id: authorization_context.tenant_id]

    Database.transaction(
      conn,
      fn transaction_conn ->
        messages = [
          Message.changeset(%Message{}, %{
            topic: authorization_context.topic,
            extension: :broadcast
          }),
          Message.changeset(%Message{}, %{
            topic: authorization_context.topic,
            extension: :presence
          })
        ]

        {:ok, messages} = Repo.insert_all_entries(transaction_conn, messages, Message)

        {[%{id: broadcast_id}], [%{id: presence_id}]} =
          Enum.split_with(messages, &(&1.extension == :broadcast))

        set_conn_config(transaction_conn, authorization_context)

        policies =
          get_read_policy_for_connection_and_extension(
            transaction_conn,
            authorization_context,
            broadcast_id,
            presence_id,
            policies
          )

        Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])
        policies
      end,
      opts
    )
  end

  defp get_write_policies_for_connection(conn, authorization_context, policies) do
    opts = [telemetry: [:realtime, :tenants, :write_authorization_check], tenant_id: authorization_context.tenant_id]

    Database.transaction(
      conn,
      fn transaction_conn ->
        set_conn_config(transaction_conn, authorization_context)

        policies =
          get_write_policy_for_connection_and_extension(
            transaction_conn,
            authorization_context,
            policies
          )

        Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])

        policies
      end,
      opts
    )
  end

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

    with {:ok, res} <- Repo.all(conn, query, Message) do
      can_presence? = Enum.any?(res, fn %{id: id} -> id == presence_id end)
      can_broadcast? = Enum.any?(res, fn %{id: id} -> id == broadcast_id end)

      policies
      |> Policies.update_policies(:presence, :read, can_presence?)
      |> Policies.update_policies(:broadcast, :read, can_broadcast?)
    end
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

    policies =
      case Repo.insert(conn, broadcast_changeset, Message, mode: :savepoint) do
        {:ok, _} ->
          Policies.update_policies(policies, :broadcast, :write, true)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Policies.update_policies(policies, :broadcast, :write, false)

        e ->
          e
      end

    case Repo.insert(conn, presence_changeset, Message, mode: :savepoint) do
      {:ok, _} ->
        Policies.update_policies(policies, :presence, :write, true)

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        Policies.update_policies(policies, :presence, :write, false)

      e ->
        e
    end
  end
end
