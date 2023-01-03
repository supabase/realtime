defmodule Realtime.SignalHandler do
  @moduledoc false
  @behaviour :gen_event
  require Logger

  @spec shutdown_in_progress? :: boolean()
  def shutdown_in_progress? do
    !!Application.get_env(:realtime, :shutdown_in_progress)
  end

  @impl true
  def init(_) do
    Logger.info("#{__MODULE__} is being initialized...")
    {:ok, %{}}
  end

  @impl true
  def handle_event(signal, state) do
    Logger.warn("#{__MODULE__}: #{inspect(signal)} received")

    if signal == :sigterm do
      Application.put_env(:realtime, :shutdown_in_progress, true)
    end

    :erl_signal_handler.handle_event(signal, state)
  end

  @impl true
  defdelegate handle_info(info, state), to: :erl_signal_handler

  @impl true
  defdelegate handle_call(request, state), to: :erl_signal_handler
end
