defmodule Realtime.TokenBucket do
  @moduledoc """
  A token bucket that holds up to `burst` tokens and refills at `rate` tokens per second.

  The bucket is one atomic integer, so the process that creates it can share it with other processes. For example,
  `RealtimeWeb.UserSocket` creates one bucket for each WebSocket connection, and each channel of that connection
  takes a token when it joins.

  ## How the bucket works

  The bucket uses GCRA (generic cell rate algorithm), a token bucket kept as one timestamp. It does not keep a count
  of the tokens left. `Realtime.Tenants.NodeJoinBudget` uses the same algorithm.

  Each token costs one interval of time. The interval is `1 / rate` seconds, so 1 second at a rate of 1. The atomic
  holds one timestamp: `full_at`. If nothing takes a token, the bucket is full again at `full_at`. Each take moves
  `full_at` one interval later, and the time that passes refills the bucket. The bucket refuses a take when `full_at`
  is more than `burst - 1` intervals past now.

  For example, at a rate of 1 and a burst of 20:

    1. A new bucket is full, so its `full_at` is now.
    2. 20 takes at once move `full_at` to now + 20 seconds.
    3. Take 21 finds `full_at` 20 seconds ahead, past the 19 seconds allowed, so the bucket refuses it.
    4. One second later, `full_at` is only 19 seconds ahead, so 1 more take fits.

  While `full_at` is ahead of now the tokens left are `burst - (full_at - now) / interval`, rounded down.
  """

  @microseconds_per_second 1_000_000

  @enforce_keys [:ref, :interval, :tolerance]
  defstruct [:ref, :interval, :tolerance]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref(), interval: non_neg_integer(), tolerance: non_neg_integer()}

  @doc "Creates a full bucket."
  @spec new(pos_integer(), pos_integer(), integer()) :: t()
  def new(rate, burst, now \\ now()) when is_integer(rate) and rate > 0 and is_integer(burst) and burst > 0 do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, now)
    interval = div(@microseconds_per_second, rate)

    %__MODULE__{ref: ref, interval: interval, tolerance: (burst - 1) * interval}
  end

  @doc "Takes a token, or returns `:error` without changing the bucket when it is empty."
  @spec take(t(), integer()) :: :ok | :error
  def take(%__MODULE__{ref: ref, interval: interval, tolerance: tolerance} = bucket, now \\ now()) do
    full_at = :atomics.get(ref, 1)
    next_full_at = max(full_at, now)

    # Another process holding the bucket can take a token between the read above and the write below.
    # A plain put would overwrite its take and hand out a token twice, so the write only lands if the
    # atomic is unchanged.
    #
    # The recursive retry ends: an exchange only fails because another take succeeded, each success moves
    # `full_at` at least one interval forward, and `now` stays fixed across retries, so after about
    # `burst` of them this take reaches the `:error` branch regardless. It is also a tail call and
    # retrying doesn't grow the stack.
    cond do
      next_full_at - now > tolerance -> :error
      :atomics.compare_exchange(ref, 1, full_at, next_full_at + interval) == :ok -> :ok
      true -> take(bucket, now)
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
end
