defmodule Realtime.Messages do
  @moduledoc """
  Module to handle messages
  """
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo

  @doc """
  Creates a message given channel name in the tenant database using a given DBConnection.

  This tables will be used for to set Authorizations. Please read more at Realtime.Tenants.Authorization
  """
  def create_message(attrs, conn, opts \\ [mode: :savepoint]) do
    channel = Message.changeset(%Message{}, attrs)

    result =
      Database.transaction(conn, fn transaction_conn ->
        with {:ok, %Message{} = channel} <- Repo.insert(transaction_conn, channel, Message, opts) do
          channel
        end
      end)

    case result do
      %Ecto.Changeset{valid?: false} = error -> {:error, error}
      {:error, error} -> {:error, error}
      result -> {:ok, result}
    end
  end
end
