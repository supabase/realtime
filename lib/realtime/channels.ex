defmodule Realtime.Channels do
  @moduledoc """
  Handles Channel related operations
  """

  alias Realtime.Api.Broadcast
  alias Realtime.Api.Channel
  alias Realtime.Api.Presence
  alias Realtime.Helpers
  alias Realtime.Repo

  import Ecto.Query

  @doc """
  Lists all channels in the tenant database using a given DBConnection
  """
  @spec list_channels(DBConnection.conn()) :: {:error, any()} | {:ok, [struct()]}
  def list_channels(conn) do
    Helpers.transaction(conn, fn db_conn -> Repo.all(db_conn, Channel, Channel) end)
  end

  @doc """
  Fetches a channel by id from the tenant database using a given DBConnection
  """
  @spec get_channel_by_id(binary(), DBConnection.conn()) :: {:ok, Channel.t()} | {:error, any()}
  def get_channel_by_id(id, conn) do
    query = from c in Channel, where: c.id == ^id

    Helpers.transaction(conn, fn transaction_conn ->
      Repo.one(transaction_conn, query, Channel)
    end)
  end

  @spec create_channel(
          map(),
          DBConnection.t(),
          Postgrex.option() | Keyword.t()
        ) :: {:error, any()} | {:ok, Channel.t()}
  @doc """
  Creates a channel and supporting tables for a given channel in the tenant database using a given DBConnection.

  This tables will be used for to set Authorizations. Please read more at Realtime.Tenants.Authorization
  """
  def create_channel(attrs, conn, opts \\ [mode: :savepoint]) do
    channel = Channel.changeset(%Channel{}, attrs)

    result =
      Helpers.transaction(conn, fn transaction_conn ->
        with {:ok, %Channel{} = channel} <-
               Repo.insert(transaction_conn, channel, Channel, opts),
             broadcast_changeset = Broadcast.changeset(%Broadcast{}, %{channel_id: channel.id}),
             presence_changeset = Broadcast.changeset(%Presence{}, %{channel_id: channel.id}),
             {:ok, _} <- Repo.insert(transaction_conn, broadcast_changeset, Broadcast, opts),
             {:ok, _} <- Repo.insert(transaction_conn, presence_changeset, Presence, opts) do
          channel
        end
      end)

    case result do
      %Ecto.Changeset{valid?: false} = error -> {:error, error}
      {:error, error} -> {:error, error}
      result -> {:ok, result}
    end
  end

  @doc """
  Fetches a channel by name from the tenant database using a given DBConnection
  """
  @spec get_channel_by_name(String.t(), DBConnection.conn()) ::
          {:ok, Channel.t()} | {:error, any()}
  def get_channel_by_name(name, conn) do
    query = from c in Channel, where: c.name == ^name

    Helpers.transaction(conn, fn transaction_conn ->
      Repo.one(transaction_conn, query, Channel)
    end)
  end

  @doc """
  Deletes a channel by name from the tenant database using a given DBConnection
  """
  @spec delete_channel_by_name(binary(), DBConnection.conn()) ::
          :ok | {:error, any()}
  def delete_channel_by_name(name, conn) do
    query = from c in Channel, where: c.name == ^name

    Helpers.transaction(conn, fn transaction_conn ->
      case Repo.del(transaction_conn, query) do
        {:ok, 1} -> :ok
        {:ok, 0} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @doc """
  Updates a channel by name from the tenant database using a given DBConnection
  """
  @spec update_channel_by_name(binary(), map(), DBConnection.conn()) ::
          {:ok, Channel.t()} | {:error, any()}
  def update_channel_by_name(name, attrs, conn) do
    with {:ok, channel} when not is_nil(channel) <- get_channel_by_name(name, conn) do
      channel = Channel.changeset(channel, attrs)

      Helpers.transaction(conn, fn transaction_conn ->
        Repo.update(transaction_conn, channel, Channel)
      end)
    end
  end
end
