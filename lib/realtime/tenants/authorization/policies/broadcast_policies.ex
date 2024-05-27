defmodule Realtime.Tenants.Authorization.Policies.BroadcastPolicies do
  @moduledoc """
  BroadcastPolicies structure that holds the required authorization information for a given connection within the scope of a sending / receiving broadcasts messages

  Uses the Realtime.Api.Broadcast to try reads and writes on the database to determine authorization for a given connection.

  Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query
  import Realtime.Helpers, only: [log_error: 2, to_log: 1]

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
  def check_read_policies(_conn, policies, %Authorization{topic: nil}) do
    {:ok, Policies.update_policies(policies, :broadcast, :read, false)}
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{topic: topic}) do
    query =
      from(m in Message,
        where: m.topic == ^topic,
        where: m.extension == :broadcast,
        limit: 1
      )

    case Repo.all(conn, query, Message, mode: :savepoint) do
      {:ok, []} ->
        {:ok, Policies.update_policies(policies, :broadcast, :read, false)}

      {:ok, [%Message{}]} ->
        {:ok, Policies.update_policies(policies, :broadcast, :read, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :broadcast, :read, false)}

      {:error, error} ->
        log_error(
          "UnableToSetPolicies",
          "Error getting policies for connection: #{to_log(error)}"
        )

        Postgrex.rollback(conn, error)
    end
  end

  @impl true
  def check_write_policies(_conn, policies, %Authorization{topic: nil}) do
    {:ok, Policies.update_policies(policies, :broadcast, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{topic: topic}) do
    changeset =
      Message.changeset(%Message{}, %{topic: topic, extension: :broadcast})

    case Repo.insert(conn, changeset, Message, mode: :savepoint) do
      {:ok, %Message{}} ->
        Postgrex.query!(conn, "ROLLBACK AND CHAIN", [])
        {:ok, Policies.update_policies(policies, :broadcast, :write, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :broadcast, :write, false)}

      {:error, error} ->
        log_error(
          "UnableToSetPolicies",
          "Error getting policies for connection: #{to_log(error)}"
        )
    end
  end
end
