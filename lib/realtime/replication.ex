
# WORKING VERSION

alias Cainophile.Changes.{
  Transaction,
  NewRecord,
  UpdatedRecord,
  DeletedRecord,
  TruncatedRelation
}

import Protocol
Protocol.derive(Jason.Encoder, Cainophile.Changes.Transaction)
Protocol.derive(Jason.Encoder, Cainophile.Changes.NewRecord)
Protocol.derive(Jason.Encoder, Cainophile.Changes.UpdatedRecord)
Protocol.derive(Jason.Encoder, Cainophile.Changes.DeletedRecord)
Protocol.derive(Jason.Encoder, Cainophile.Changes.TruncatedRelation)

defmodule Realtime.Replication do
  use GenServer
  require Logger


  @doc """
  Initialize the GenServer
  """
  @spec start_link([String.t], [any])  :: {:ok, pid}
  def start_link(channel, otp_opts \\ []), do: GenServer.start_link(__MODULE__, channel, otp_opts)

  @doc """
  When the GenServer starts subscribe to the given channel
  """
  @spec init([String.t])  :: {:ok, []}
  def init(channel) do
    Logger.debug("Starting REPLICATION #{channel}")
    Logger.debug("Starting REPLICATION")

    Cainophile.Adapters.Postgres.subscribe(Cainophile.RealtimeListener, self())
    {:ok, {}}
  end

  def handle_info(payload, _commit_timestamp) do
    Logger.debug("GOT REPLICATION!!")
    Logger.debug("#{inspect(payload)}")

    %Transaction{changes: changes, commit_timestamp: commit_timestamp} = payload
    # [%UpdatedRecord{}, %DeletedRecord{}, %NewRecord{}] = changes
    # payload = Jason.encode!(payload)
    # Logger.debug("#{inspect(payload)}")

    # Enum.each changes, fn x ->
    #   Logger.debug("changes!!")
    #   Logger.debug("changes!!")
    #   Logger.debug("#{inspect(changes)}")
    #   Logger.debug("#{inspect(changes)}")
    # end

    RealtimeWeb.RealtimeChannel.handle_info(payload)
    {:noreply, :event_received}
  end

end