defmodule Realtime.Tenants.Authorization.Policies.BroadcastPolicies do
  @moduledoc """
  BroadcastPolicies structure that holds the required authorization information for a given connection within the scope of a sending / receiving broadcasts messages

  Uses the Realtime.Api.Broadcast to try reads and writes on the database to determine authorization for a given connection.

  Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query
  import Realtime.Helpers, only: [log_error: 2, to_log: 1]

  alias Realtime.Api.Broadcast
  alias Realtime.Api.Channel
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
  def check_read_policies(_conn, policies, %Authorization{channel: nil}) do
    {:ok, Policies.update_policies(policies, :broadcast, :read, false)}
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    Postgrex.transaction(conn, fn transaction_conn ->
      query = from(b in Broadcast, where: b.channel_id == ^channel_id)

      case Repo.one(conn, query, Broadcast, mode: :savepoint) do
        {:ok, %Broadcast{}} ->
          Policies.update_policies(policies, :broadcast, :read, true)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Policies.update_policies(policies, :broadcast, :read, false)

        {:error, :not_found} ->
          Policies.update_policies(policies, :broadcast, :read, false)

        {:error, error} ->
          log_error(
            "UnableToSetPolicies",
            "Error getting policies for connection: #{to_log(error)}"
          )

          Postgrex.rollback(transaction_conn, error)
      end
    end)
  end

  @impl true
  def check_write_policies(_conn, policies, %Authorization{channel: nil}) do
    {:ok, Policies.update_policies(policies, :broadcast, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    Postgrex.transaction(conn, fn transaction_conn ->
      query = from(b in Broadcast, where: b.channel_id == ^channel_id)

      case Repo.one(conn, query, Broadcast, mode: :savepoint) do
        {:ok, %Broadcast{} = broadcast} ->
          zero = NaiveDateTime.new!(~D[1970-01-01], ~T[00:00:00])
          changeset = Broadcast.check_changeset(broadcast, %{updated_at: zero})

          case Repo.update(conn, changeset, Broadcast, mode: :savepoint) do
            {:ok, %Broadcast{updated_at: ^zero}} ->
              Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])
              Policies.update_policies(policies, :broadcast, :write, true)

            {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
              Policies.update_policies(policies, :broadcast, :write, false)

            {:error, :not_found} ->
              Policies.update_policies(policies, :broadcast, :write, false)

            {:error, error} ->
              log_error(
                "UnableToSetPolicies",
                "Error getting policies for connection: #{to_log(error)}"
              )
          end

        {:error, :not_found} ->
          Policies.update_policies(policies, :broadcast, :write, false)
      end
    end)
  end
end
