defmodule Realtime.Tenants.Authorization.Policies.PresencePolicies do
  @moduledoc """
    PresencePolicies structure that holds the required authorization information for a given connection within the scope of a tracking / receiving presence messages

    Uses the Realtime.Api.Presence to try reads and writes on the database to determine authorization for a given connection.

    Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query
  import Realtime.Helpers, only: [to_log: 1, log_error: 2]

  alias Realtime.Api.Message
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies

  defstruct read: false, write: false

  @behaviour Realtime.Tenants.Authorization.Policies

  @type t :: %__MODULE__{
          read: boolean(),
          write: boolean()
        }
  @impl true
  def check_read_policies(_conn, policies, %Authorization{channel_name: nil}) do
    {:ok, Policies.update_policies(policies, :presence, :read, false)}
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{channel_name: channel_name}) do
    query =
      from(m in Message,
        where: m.channel_name == ^channel_name,
        where: m.feature == :presence,
        limit: 1
      )

    case Repo.all(conn, query, Message, mode: :savepoint) do
      {:ok, []} ->
        {:ok, Policies.update_policies(policies, :presence, :read, false)}

      {:ok, [%Message{}]} ->
        {:ok, Policies.update_policies(policies, :presence, :read, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :presence, :read, false)}

      {:error, error} ->
        log_error(
          "UnableToSetPolicies",
          "Error getting policies for connection: #{to_log(error)}"
        )

        Postgrex.rollback(conn, error)
    end
  end

  @impl true
  def check_write_policies(_conn, policies, %Authorization{channel_name: nil}) do
    {:ok, Policies.update_policies(policies, :presence, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{channel_name: channel_name}) do
    changeset =
      Message.changeset(%Message{}, %{
        channel_name: channel_name,
        feature: :presence,
        event: "check_write_policy"
      })

    case Repo.insert(conn, changeset, Message, mode: :savepoint) do
      {:ok, %Message{}} ->
        Postgrex.query!(conn, "ROLLBACK AND CHAIN", [])
        {:ok, Policies.update_policies(policies, :presence, :write, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :presence, :write, false)}

      {:error, error} ->
        log_error(
          "UnableToSetPolicies",
          "Error getting policies for connection: #{to_log(error)}"
        )

        Postgrex.rollback(conn, error)
    end
  end
end
