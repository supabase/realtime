defmodule Realtime.Adapters.Postgres.AdapterBehaviour do
  @callback init(config :: term) ::
              {:ok, %Realtime.Replication.State{}} | {:stop, reason :: binary}

  @callback acknowledge_lsn(connection :: pid, {xlog :: integer, offset :: integer}) :: :ok
end
