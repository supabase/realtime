# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE
defmodule Realtime.Adapters.Postgres.AdapterBehaviour do
  @callback init(config :: term) ::
              {:ok, %Realtime.Replication.State{}} | {:stop, reason :: binary}

  @callback acknowledge_lsn(connection :: pid, {xlog :: integer, offset :: integer}) :: :ok
end
