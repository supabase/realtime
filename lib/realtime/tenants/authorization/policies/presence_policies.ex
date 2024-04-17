defmodule Realtime.Tenants.Authorization.Policies.PresencePolicies do
  @moduledoc """
    PresencePolicies structure that holds the required authorization information for a given connection within the scope of a tracking / receiving presence messages

    Uses the Realtime.Api.Presence to try reads and writes on the database to determine authorization for a given connection.

    Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query

  alias Realtime.Api.Presence
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
    {:ok, Policies.update_policies(policies, :presence, :read, false)}
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    Postgrex.transaction(conn, fn transaction_conn ->
      query = from(b in Presence, where: b.channel_id == ^channel_id)

      case Repo.one(conn, query, Presence, mode: :savepoint) do
        {:ok, %Presence{}} ->
          Policies.update_policies(policies, :presence, :read, true)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Policies.update_policies(policies, :presence, :read, false)

        {:error, :not_found} ->
          Policies.update_policies(policies, :presence, :read, false)

        {:error, error} ->
          Logger.error("Error getting broadcast read policies for connection: #{inspect(error)}")

          Postgrex.rollback(transaction_conn, error)
      end
    end)
  end

  @impl true
  def check_write_policies(_conn, policies, %Authorization{channel: nil}) do
    {:ok, Policies.update_policies(policies, :presence, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    Postgrex.transaction(conn, fn transaction_conn ->
      query = from(b in Presence, where: b.channel_id == ^channel_id)

      case Repo.one(conn, query, Presence, mode: :savepoint) do
        {:ok, %Presence{} = broadcast} ->
          zero = NaiveDateTime.new!(~D[1970-01-01], ~T[00:00:00])
          changeset = Presence.check_changeset(broadcast, %{updated_at: zero})

          case Repo.update(conn, changeset, Presence, mode: :savepoint) do
            {:ok, %Presence{updated_at: ^zero}} ->
              Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])
              Policies.update_policies(policies, :presence, :write, true)

            {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
              Policies.update_policies(policies, :presence, :write, false)

            {:error, :not_found} ->
              Policies.update_policies(policies, :presence, :write, false)

            {:error, error} ->
              Logger.error(
                "Error getting broadcast write policies for connection: #{inspect(error)}"
              )

              Postgrex.rollback(transaction_conn, error)
          end

        {:error, :not_found} ->
          Policies.update_policies(policies, :presence, :write, false)
      end
    end)
  end
end
