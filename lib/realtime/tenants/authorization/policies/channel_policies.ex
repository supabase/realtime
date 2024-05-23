defmodule Realtime.Tenants.Authorization.Policies.ChannelPolicies do
  @moduledoc """
  ChannelPolicies structure that holds the required authorization information for a given connection within the scope of a reading / altering channel entities

  Uses the Realtime.Api.Channel to try reads and writes on the database to determine authorization for a given connection.

  > Note: Currently we only allow policies to read all but not write all IF the RLS policies allow it.

  Implements Realtime.Tenants.Authorization behaviour.
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
  def check_read_policies(_conn, %Policies{} = policies, %Authorization{channel_name: nil}) do
    {:ok, Policies.update_policies(policies, :channel, :read, false)}
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{channel_name: channel_name}) do
    query = from(m in Message, where: m.channel_name == ^channel_name)

    case Repo.all(conn, query, Message, mode: :savepoint) do
      {:ok, []} ->
        {:ok, Policies.update_policies(policies, :channel, :read, false)}

      {:ok, [%Message{} | _]} ->
        {:ok, Policies.update_policies(policies, :channel, :read, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :channel, :read, false)}

      {:error, :not_found} ->
        {:ok, Policies.update_policies(policies, :channel, :read, false)}

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
    {:ok, Policies.update_policies(policies, :channel, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{channel_name: channel_name}) do
    changeset =
      Message.changeset(%Message{}, %{
        channel_name: channel_name,
        feature: :presence,
        event: "test"
      })

    case Repo.insert(conn, changeset, Message, mode: :savepoint) do
      {:ok, %Message{}} ->
        Postgrex.query!(conn, "ROLLBACK AND CHAIN", [])
        {:ok, Policies.update_policies(policies, :channel, :write, true)}

      %Ecto.Changeset{errors: [name: {"has already been taken", []}]} ->
        {:ok, Policies.update_policies(policies, :channel, :write, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :channel, :write, false)}

      {:error, error} ->
        log_error(
          "UnableToSetPolicies",
          "Error getting policies for connection: #{to_log(error)}"
        )

        Postgrex.rollback(conn, error)
    end
  end
end
