defmodule Realtime.Channels do
  @moduledoc """
  Handles Channel related operations
  """

  alias Realtime.Api.Channel
  alias Realtime.Repo

  import Ecto.Query

  @doc """
  Lists all channels in the tenant database using a given DBConnection
  """
  @spec list_channels(DBConnection.conn()) :: {:error, any()} | {:ok, [struct()]}
  def list_channels(conn) do
    Repo.all(conn, Channel, Channel)
  end

  @doc """
  Fetches a channel by id from the tenant database using a given DBConnection
  """
  @spec get_channel_by_id(binary(), DBConnection.conn()) :: {:ok, Channel.t()} | {:error, any()}
  def get_channel_by_id(id, conn) do
    query = from c in Channel, where: c.id == ^id
    Repo.one(conn, query, Channel)
  end

  @doc """
  Creates a channel in the tenant database using a given DBConnection
  """
  @spec create_channel(map(), DBConnection.conn()) :: {:ok, Channel.t()} | {:error, any()}
  def create_channel(attrs, conn) do
    channel = Channel.changeset(%Channel{}, attrs)

    Repo.insert(conn, channel, Channel)
  end

  @doc """
  Fetches a channel by name from the tenant database using a given DBConnection
  """
  @spec get_channel_by_name(String.t(), DBConnection.conn()) ::
          {:ok, Channel.t()} | {:error, any()}
  def get_channel_by_name(name, conn) do
    query = from c in Channel, where: c.name == ^name
    Repo.one(conn, query, Channel)
  end

  @doc """
  Deletes a channel by id from the tenant database using a given DBConnection
  """
  @spec delete_channel_by_id(binary(), DBConnection.conn()) ::
          :ok | {:error, any()}
  def delete_channel_by_id(id, conn) do
    query = from c in Channel, where: c.id == ^id

    with {:ok, 1} <- Repo.del(conn, query) do
      :ok
    else
      {:ok, 0} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Updates a channel by id from the tenant database using a given DBConnection
  """
  @spec update_channel_by_id(binary(), map(), DBConnection.conn()) ::
          {:ok, Channel.t()} | {:error, any()}
  def update_channel_by_id(id, attrs, conn) do
    with {:ok, channel} when not is_nil(channel) <- get_channel_by_id(id, conn) do
      channel = Channel.changeset(channel, attrs)
      Repo.update(conn, channel, Channel)
    end
  end
end
