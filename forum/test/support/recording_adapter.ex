defmodule Forum.RecordingAdapter do
  @moduledoc """
  Test adapter that delegates broadcast/send/register to `Forum.Adapter.ErlDist`
  and routes `call/6` through a per-scope test-controlled response.

  Tests configure behavior via `configure/2`:

    * `:test_pid` — pid to notify of every adapter event (`{:adapter_event, event}`).
    * `:call_response` — response for `call/6` (`:ok | {:error, term} | {:fn, fun}`).

  When the `:call_response` is `{:fn, fun}`, the fun is invoked synchronously
  in the calling process — this lets tests inject sleeps or arbitrary logic.

  `call/6` does NOT actually invoke the remote function — it only records the
  invocation and returns the configured response. This lets tests assert
  call-shape (module/function/args) without standing up cross-node infra.
  """

  @behaviour Forum.Adapter

  ## Configuration API

  def configure(scope, opts) do
    if pid = opts[:test_pid] do
      :persistent_term.put({__MODULE__, scope, :test_pid}, pid)
    end

    if response = opts[:call_response] do
      :persistent_term.put({__MODULE__, scope, :call_response}, response)
    end

    :ok
  end

  def reset(scope) do
    :persistent_term.erase({__MODULE__, scope, :test_pid})
    :persistent_term.erase({__MODULE__, scope, :call_response})
    :ok
  end

  ## Forum.Adapter callbacks

  @impl true
  def register(scope), do: Forum.Adapter.ErlDist.register(scope)

  @impl true
  def broadcast(scope, message) do
    notify(scope, {:broadcast, scope, message})
    Forum.Adapter.ErlDist.broadcast(scope, message)
  end

  @impl true
  def broadcast(scope, nodes, message) do
    notify(scope, {:broadcast, scope, nodes, message})
    Forum.Adapter.ErlDist.broadcast(scope, nodes, message)
  end

  @impl true
  def send(scope, node, message) do
    notify(scope, {:send, scope, node, message})

    if node == node() do
      Forum.Adapter.ErlDist.send(scope, node, message)
    else
      :ok
    end
  end

  @impl true
  def call(scope, node, module, function, args, _timeout) do
    notify(scope, {:call, scope, node, module, function, args})

    case :persistent_term.get({__MODULE__, scope, :call_response}, :ok) do
      {:fn, fun} -> fun.()
      response -> response
    end
  end

  defp notify(scope, event) do
    case :persistent_term.get({__MODULE__, scope, :test_pid}, nil) do
      nil -> :ok
      pid -> Kernel.send(pid, {:adapter_event, event})
    end
  end
end
