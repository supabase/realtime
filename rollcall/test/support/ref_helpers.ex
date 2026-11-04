defmodule Rollcall.RefHelpers do
  @moduledoc """
  Builds refs for tests that call `Rollcall.Tracker.Local` or build entries
  without a tracker. A tracker makes its own refs.
  """

  @doc "Returns a ref that no other call returns in this VM."
  @spec unique_ref() :: Rollcall.ref()
  def unique_ref, do: "ref-#{System.unique_integer([:positive])}"
end
