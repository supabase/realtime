defmodule Multiplayer.SessionsHooksProducer do
  use GenStage
  require Logger

  alias Multiplayer.SessionsHooks

  @timeout_check_queue 1000
  @events_batch 50

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, %{})
  end

  @impl true
  def init(_opts) do
    Logger.debug("Started SessionsHooksProducer", [pid: self()])
    send(self(), :check_queue)
    {:producer, %{timer: make_ref(), empty: false}}
  end

  @impl true
  def handle_info(:check_queue, %{timer: ref} = state) do
    Process.cancel_timer(ref)
    case SessionsHooks.take(@events_batch) do
      [] ->
        {:noreply, [], %{state | timer: Process.send_after(
                                          self(),
                                          :check_queue,
                                          @timeout_check_queue
                                        )}}
      hooks ->
        Logger.debug("New sessions hooks")
        {:noreply, hooks, %{state | empty: false}}
    end
  end

  @impl true
  def handle_demand(_demand, %{empty: true} = state) do
    {:noreply, [], state}
  end

  def handle_demand(_demand, state) do
    case SessionsHooks.take(@events_batch) do
      [] ->
        send(self(), :check_queue)
        Logger.debug("Sessions hooks are empty")
        {:noreply, [], %{state | empty: true}}
      hooks ->
        {:noreply, hooks, state}
    end
  end

end
