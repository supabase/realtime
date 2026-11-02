defmodule Rollcall.Tracker.State do
  @moduledoc """
  The state of a tracker process.

  `local` holds the entries that processes on this node track. `version`
  counts the changes to `local`. `incarnation` is the monotonic time at which
  the tracker started. `sent` holds the `local` set and the `version` at the last
  heartbeat. The struct has no `sent` field yet.

  The `incarnation` and the `version` form the stamp of a message. A peer
  compares stamps to order messages that arrive in any order. A tracker that
  restarts gets a newer incarnation, so its peers replace its old entries.

  Monotonic time orders the incarnations of one VM only. A peer keeps one
  record for each node name, so a node that restarts under a new name gets a
  new record, and no order between VMs is needed.

  This design assumes that a node restart does not reuse a node name. A new VM
  that reuses a name can start with a lower incarnation. The peers then treat
  its messages as stale. A stale message still resets the silent count, so the
  silence threshold never purges the old record, and the old entries stay, under
  a very specific time drift that goes backwards during a node restart.

  `peers` maps each peer node to its `Rollcall.Tracker.Peer`. The view of the
  tracker is `local` plus the replica of each peer. `silence_threshold` is the
  number of ticks without a message after which the tracker deletes a peer
  record.

  `monitors` maps each process that has an entry to its monitor. `empty_grace`
  and `empty_timer` control the stop of a tracker that holds no entry.
  """

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Messages
  alias Rollcall.Tracker.Peer

  # `local` has no default. A default runs `Local.new/0` at compile time, and
  # the struct would then hold a literal value of the opaque type `Local.t()`.
  @enforce_keys [
    :scope,
    :incarnation,
    :empty_grace,
    :local,
    :silence_threshold,
    :transport_module,
    :transport_state,
    :heartbeat_period
  ]

  defstruct [
    :scope,
    :incarnation,
    :empty_grace,
    :local,
    :silence_threshold,
    :transport_module,
    :transport_state,
    :heartbeat_period,
    empty_timer: nil,
    version: 0,
    monitors: %{},
    peers: %{}
  ]

  @type t :: %__MODULE__{
          scope: Rollcall.scope(),
          incarnation: integer(),
          empty_grace: non_neg_integer(),
          empty_timer: reference() | nil,
          heartbeat_period: pos_integer() | :manual,
          local: Local.t(),
          version: non_neg_integer(),
          monitors: %{pid() => reference()},
          peers: %{node() => Peer.t()},
          silence_threshold: pos_integer(),
          transport_module: module(),
          transport_state: any()
        }

  @doc """
  Sets `local`. The version increases by one when `changes` is not empty.
  """
  @spec apply_changes(t(), Local.t(), Changes.t()) :: t()
  def apply_changes(%__MODULE__{} = state, local, changes) do
    state = %{state | local: local}

    if Changes.empty?(changes) do
      state
    else
      bump_version(state)
    end
  end

  @spec bump_version(t()) :: t()
  defp bump_version(%__MODULE__{version: version} = state) do
    %{state | version: version + 1}
  end

  @spec current_stamp(t()) :: Messages.stamp()
  def current_stamp(%__MODULE__{incarnation: incarnation, version: version}) do
    Messages.stamp(incarnation, version)
  end

  @inspectable_keys [:incarnation, :scope, :version, :local, :peers]

  @typedoc "The fields of the state that have a meaning outside the process."
  @type view :: %{
          scope: Rollcall.scope(),
          version: non_neg_integer(),
          incarnation: integer(),
          local: Local.t(),
          peers: %{node() => Peer.t()}
        }

  @doc """
  Returns the fields of the state that have a meaning outside the process.

  The timer, the monitors and the transport stay private, so a change to them
  does not break a caller.
  """
  @spec inspect_view(t()) :: view()
  def inspect_view(%__MODULE__{} = state) do
    Map.take(state, @inspectable_keys)
  end

  @doc "Returns the record of the peer on `node`, or `nil` when no message came from that node."
  @spec peer(t(), node()) :: Peer.t() | nil
  def peer(%__MODULE__{peers: peers}, node) do
    Map.get(peers, node)
  end

  @doc "Sets the record of the peer on `node`."
  @spec put_peer(t(), node(), Peer.t()) :: t()
  def put_peer(%__MODULE__{peers: peers} = state, node, %Peer{} = peer) do
    %{state | peers: Map.put(peers, node, peer)}
  end

  @doc """
  Returns the stamp of the goodbye: the incarnation and the version plus one.
  """
  @spec goodbye_stamp(t()) :: Messages.stamp()
  def goodbye_stamp(%__MODULE__{incarnation: incarnation, version: version}) do
    Messages.stamp(incarnation, version + 1)
  end
end
