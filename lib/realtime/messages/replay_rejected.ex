defmodule Realtime.Messages.ReplayRejected do
  @moduledoc """
  A broadcast replay request that Realtime refused to serve.

  The client can act on this by changing the request: sending valid replay params, or joining a
  private channel instead of a public one.
  """
  use Errata.DomainError,
    default_message: "Realtime rejected the replay request",
    code: "UnableToReplayMessages",
    reasons: [:invalid_params, :public_channel]

  def display_message(%{reason: :invalid_params}), do: "Replay params are not valid"
  def display_message(%{reason: :public_channel}), do: "Replay is not allowed for public channels"
  def display_message(error), do: error.message
end
