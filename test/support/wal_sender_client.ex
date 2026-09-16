defmodule WalSenderClient do
  @moduledoc false
  # Direct Postgres reserves a WAL sender at replication-protocol startup.
  # Keep it occupied without consuming a replication slot as well.
  use Postgrex.ReplicationConnection

  def start_link(opts) do
    Postgrex.ReplicationConnection.start_link(
      __MODULE__,
      nil,
      Keyword.merge(opts, sync_connect: true, auto_reconnect: false)
    )
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_connect(state), do: {:query, "IDENTIFY_SYSTEM", state}

  @impl true
  def handle_result([%Postgrex.Result{}], state), do: {:noreply, state}
end
