defmodule Rollcall.Tracker.Entry do
  @moduledoc """
  An entry that a process tracks.

  The `ref` identifies the entry. The `key` and the `meta` are the payload.

  In a local entry, `pid` is the process that tracks the entry. In a replica
  entry, `pid` is the origin: the tracker that sent the entry. Do not use `id/1`
  on a replica entry. Two processes of one node with the same key get the same
  id. Use the `ref`.
  """
  @enforce_keys [:partition, :pid, :key, :ref, :meta]
  defstruct [:partition, :pid, :key, :ref, :meta]

  @type id :: {pid(), Rollcall.partition(), Rollcall.key()}

  @type t :: %__MODULE__{
          partition: Rollcall.partition(),
          pid: pid(),
          key: Rollcall.key(),
          ref: Rollcall.ref(),
          meta: Rollcall.meta()
        }

  @doc "Returns an entry."
  @spec new(
          pid(),
          Rollcall.partition(),
          Rollcall.key(),
          Rollcall.meta(),
          Rollcall.ref()
        ) :: t()
  def new(pid, partition, key, meta, ref) do
    %__MODULE__{
      pid: pid,
      partition: partition,
      key: key,
      meta: meta,
      ref: ref
    }
  end

  @doc "Returns the id of `entry`."
  @spec id(t()) :: id()
  def id(%__MODULE__{} = entry) do
    id(entry.pid, entry.partition, entry.key)
  end

  @doc "Returns the id of the entry of `pid` for `key` in `partition`."
  @spec id(pid(), Rollcall.partition(), Rollcall.key()) :: id()
  def id(pid, partition, key) do
    {pid, partition, key}
  end
end
