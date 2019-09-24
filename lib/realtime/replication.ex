
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
    Logger.debug("Starting #{ __MODULE__ } with channel subscription: #{channel}")

    Cainophile.Adapters.Postgres.subscribe(Cainophile.RealtimeListener, self())
    {:ok, {}}
  end

  def handle_info(payload, _commit_timestamp) do
    # Logger.debug("GOT REPLICATION!!")

    # Enrich each change with additional details
    changes = Enum.map payload.changes, fn x ->
      # Convert the :relation tuple to a list so it can be Jason encoded
      change = Map.from_struct(%{x | relation: Tuple.to_list(x.relation)})
      # Extract the table info
      {schema, table} = x.relation
      # Enrich with the change type
      type =
        case x do
          %NewRecord{} -> "INSERT"
          %UpdatedRecord{} -> "UPDATE"
          %DeletedRecord{} -> "DELETE"
        end
      # Return enrichments
      %{change: change, type: type, schema: schema, table: table}
    end

    # Send the whole transaction
    transaction = %{payload | changes: changes}
    RealtimeWeb.RealtimeChannel.handle_info(transaction)

    # Event handled
    {:noreply, :event_received}
  end

end