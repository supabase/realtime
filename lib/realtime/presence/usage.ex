defmodule Realtime.Presence.Usage do
  @moduledoc """
  The definitions that the presence usage of every backend shares.

  The usage metrics group the topics by the number of members in a topic. The bounds of the groups
  are the same for each backend, so the series of the backends compare. `Realtime.Presence.PhoenixUsage`
  and the Rollcall usage in `Realtime.PromEx.Plugins.Presence` both use `buckets/0`.
  """

  @buckets [1, 2, 3, 5, 10, 25, 50, 100, 200, 500, 1000]

  @doc """
  Returns the upper bounds of the buckets, in ascending order.
  """
  @spec buckets() :: [pos_integer()]
  def buckets, do: @buckets
end
