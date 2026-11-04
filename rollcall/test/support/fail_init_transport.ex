defmodule Rollcall.Transport.FailInit do
  @moduledoc """
  A transport for tests that need `init/2` to fail.

  The option `:failures` is an `:atomics` ref of size 1, or `:always`. The
  value of the ref is the number of calls to `init/2` that raise. After that,
  `init/2` works and the transport behaves like
  `Rollcall.Transport.PassThrough`. With `:always`, `init/2` always raises. Use
  `:always` where the options must be a compile-time constant.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.PassThrough

  @impl true
  def init(scope, opts) do
    case Keyword.fetch!(opts, :failures) do
      :always -> raise "transport init failed"
      failures -> if :atomics.sub_get(failures, 1, 1) >= 0, do: raise("transport init failed")
    end

    PassThrough.init(scope, [])
  end

  @impl true
  defdelegate heartbeat(state, message), to: PassThrough

  @impl true
  defdelegate unwrap(state, raw), to: PassThrough
end
