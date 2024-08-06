defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo

  def broadcast_test_message(conn, private, topic, event, payload) do
    query =
      """
      select pg_notify(
          'realtime:broadcast',
          json_build_object(
              'private', $1::boolean,
              'topic', $2::text,
              'event', $3::text,
              'payload', $4::jsonb
          )::text
      );
      """

    Postgrex.query!(conn, query, [private, topic, event, %{payload: payload}])
  end

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
