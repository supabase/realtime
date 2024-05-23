defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to set policies for a given connection and
  creates a Realtime.Tenants.Policies struct with the accumulated results of the policies
  for a given user and a given channel context

  Each feature will have their own set of ways to check Policies against the Authorization context but we will create some setup data to be used by the policies.

  Check more information at Realtime.Tenants.Authorization.Policies
  """
  require Logger
  alias Realtime.Messages
  alias Realtime.Helpers
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  defstruct [:channel_name, :headers, :jwt, :claims, :role]

  @type t :: %__MODULE__{
          :channel_name => binary() | nil,
          :claims => map(),
          :headers => keyword({binary(), binary()}),
          :jwt => map(),
          :role => binary()
        }

  @doc """
  Builds a new authorization struct which will be used to retain the information required to check Policies.

  Requires a map with the following keys:
  * channel_name: The name of the channel being accessed taken from the request
  * headers: Request headers when the connection was made or WS was updated
  * jwt: JWT String
  * claims: JWT claims
  * role: JWT role
  """
  @spec build_authorization_params(map()) :: t()
  def build_authorization_params(map) do
    %__MODULE__{
      channel_name: Map.get(map, :channel_name),
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
      %Policies{} = policies -> {:ok, Phoenix.Socket.assign(socket, :policies, policies)}
      error -> {:error, error}
    end
  end

  def get_authorizations(%Plug.Conn{} = conn, db_conn, authorization_context) do
    case get_authorizations(db_conn, authorization_context) do
      %Policies{} = policies -> {:ok, Plug.Conn.assign(conn, :policies, policies)}
      error -> error
    end
  end

  @doc """
  Runs validations based on RLS policies and returns the policies
  """
  @spec get_authorizations(DBConnection.t(), __MODULE__.t()) ::
          %Policies{} | {:error, any()}
  def get_authorizations(db_conn, authorization_context) do
    case get_policies_for_connection(db_conn, authorization_context) do
      %Policies{} = policies -> policies
      error -> {:error, error}
    end
  end

  @doc """
  Sets the current connection configuration with the following config values:
  * role: The role of the user
  * realtime.channel_name: The name of the channel being accessed
  * request.jwt.claim.role: The role of the user
  * request.jwt: The JWT token
  * request.jwt.claim.sub: The sub claim of the JWT token
  * request.jwt.claims: The claims of the JWT token
  * request.headers: The headers of the request
  """
  @spec set_conn_config(DBConnection.t(), t()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def set_conn_config(conn, authorization_context) do
    %__MODULE__{
      channel_name: channel_name,
      headers: headers,
      jwt: jwt,
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
       set_config('realtime.channel_name', $2, true),
       set_config('request.jwt', $3, true),
       set_config('request.jwt.claims', $4, true),
       set_config('request.headers', $5, true)
      """,
      [role, channel_name, jwt, claims, headers]
    )
  end

  @policies_mods [ChannelPolicies, BroadcastPolicies, PresencePolicies]
  defp get_policies_for_connection(conn, authorization_context) do
    Helpers.transaction(conn, fn transaction_conn ->
      {:ok, _} =
        Messages.create_message(
          %{
            channel_name: authorization_context.channel_name,
            event: "event",
            feature: :broadcast
          },
          transaction_conn
        )

      {:ok, _} =
        Messages.create_message(
          %{
            channel_name: authorization_context.channel_name,
            event: "event",
            feature: :presence
          },
          transaction_conn
        )

      set_conn_config(transaction_conn, authorization_context)

      policies = %Policies{}

      policies =
        get_read_policy_for_connection_and_feature(
          transaction_conn,
          policies,
          authorization_context
        )

      policies =
        get_write_policy_for_connection_and_feature(
          transaction_conn,
          policies,
          authorization_context
        )

      Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])

      policies
    end)
  end

  defp get_read_policy_for_connection_and_feature(conn, policies, authorization_context) do
    Enum.reduce_while(@policies_mods, policies, fn policy_mod, policies ->
      res = policy_mod.check_read_policies(conn, policies, authorization_context)

      case res do
        {:error, error} -> {:halt, {:error, error}}
        %DBConnection.TransactionError{} = err -> {:halt, err}
        {:ok, policy} -> {:cont, policy}
      end
    end)
  end

  defp get_write_policy_for_connection_and_feature(conn, policies, authorization_context) do
    Enum.reduce_while(@policies_mods, policies, fn policy_mod, policies ->
      res = policy_mod.check_write_policies(conn, policies, authorization_context)

      case res do
        {:error, error} -> {:halt, {:error, error}}
        %DBConnection.TransactionError{} = err -> {:halt, err}
        {:ok, policy} -> {:cont, policy}
      end
    end)
  end
end
