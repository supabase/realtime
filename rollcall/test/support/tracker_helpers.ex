defmodule Rollcall.TrackerHelpers do
  @moduledoc """
  Starts trackers and builds the pids that tracker tests use as peers.
  """

  @doc """
  Starts a tracker for `scope` under the test supervisor. The tracker uses
  `silence_threshold` as its silence threshold.

  This function is the only place that passes the init parameter.
  """
  @spec start_tracker(Rollcall.scope(), pos_integer()) :: pid()
  def start_tracker(scope, silence_threshold) do
    ExUnit.Callbacks.start_supervised!({Rollcall.Tracker, {scope, silence_threshold: silence_threshold}})
  end

  @doc """
  Returns a pid on `node` with the id `id`. Use a different `id` for each pid.

  The node does not need to exist. Do not send a message to the pid or call a
  `Process` function on it.
  """
  @spec remote_pid(node(), pos_integer()) :: pid()
  def remote_pid(node, id) do
    name = Atom.to_string(node)

    :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, id::32, 0::32, 1::32>>)
  end
end
