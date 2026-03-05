defmodule Realtime.LogFilter do
  @moduledoc """
  Primary logger filter that suppresses noisy errors from dependencies.
  """

  @filter_id :connection_noise

  @doc """
  Installs the primary filter into the Erlang logger. Safe to call multiple times.
  """
  def setup do
    case :logger.add_primary_filter(@filter_id, {&filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc """
  Filter function passed to `:logger.add_primary_filter/2`.

  Returns `:stop` to suppress the event or the original event map to allow it through.
  """
  def filter(
        %{msg: {:report, %{label: {:gen_statem, :terminate}, reason: {_, %DBConnection.ConnectionError{}, _}}}},
        _
      ),
      do: :stop

  def filter(%{meta: %{mfa: {DBConnection.Connection, _, _}}}, _), do: :stop

  @ranch_format "Ranch listener ~p had connection process started with ~p:start_link/3 at ~p exit with reason: ~0p~n"
  def filter(%{msg: {:format, @ranch_format, [_, _, _, :killed]}}, _), do: :stop

  def filter(event, _), do: event
end
