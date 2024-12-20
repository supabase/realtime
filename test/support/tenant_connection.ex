defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo

  def create_message(attrs, conn, opts \\ [mode: :savepoint]) do
    channel = Message.changeset(%Message{}, attrs)

    {:ok, result} =
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
