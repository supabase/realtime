defmodule Realtime.Messages.ReplayFailed do
  @moduledoc """
  Realtime could not read the messages to replay from the tenant database.

  The `cause` is whatever the tenant `Repo` returned, and the `context` records which replay was
  being served.
  """
  use Errata.InfrastructureError,
    default_message: "Realtime was unable to replay messages",
    code: "UnableToReplayMessages"
end
