defmodule Realtime.SignalHandler do
  @moduledoc false
  @behaviour :gen_event
  require Logger

  @spec shutdown_in_progress?() :: :ok | {:error, :shutdown_in_progress}
  def shutdown_in_progress? do
    if Application.get_env(:realtime, :shutdown_in_progress),
      do: {:error, :shutdown_in_progress},
      else: :ok
  end

  @impl true
  def init({%{handler_mod: _} = args, :ok}) do
    {:ok, Map.put_new(args, :shutdown_fn, fn -> System.stop(0) end)}
  end

  @impl true
  def handle_event(signal, %{handler_mod: handler_mod} = state) do
    case signal do
      :sigterm ->
        Logger.warning("#{__MODULE__}: :sigterm received")
        Application.put_env(:realtime, :shutdown_in_progress, true)
        handler_mod.handle_event(signal, state)

      :sigint ->
        Application.put_env(:realtime, :shutdown_in_progress, true)
        Logger.notice("#{__MODULE__}: SIGINT received - shutting down")
        Task.start(state.shutdown_fn)
        {:ok, state}

      _ ->
        Logger.error("#{__MODULE__}: unexpected signal #{inspect(signal)} received")
        handler_mod.handle_event(signal, state)
    end
  end

  @impl true
  defdelegate handle_info(info, state), to: :erl_signal_handler

  @impl true
  defdelegate handle_call(request, state), to: :erl_signal_handler
end
