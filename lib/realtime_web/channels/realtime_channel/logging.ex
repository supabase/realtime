defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels to ensure
  """
  require Logger
  import Realtime.Logs

  @doc """
  Logs messages according to user options given on config
  """
  def maybe_log_handle_info(
        %{assigns: %{log_level: log_level, channel_name: channel_name}} = socket,
        msg
      ) do
    if Logger.compare_levels(log_level, :error) == :lt do
      msg = "HANDLE_INFO INCOMING ON " <> channel_name <> " message: " <> inspect(msg)
      Logger.log(log_level, msg)
    end

    socket
  end

  @doc """
  Logs errors in an expected format
  """
  @spec log_error_message(
          level :: :error | :warning,
          code :: binary(),
          error :: term(),
          keyword()
        ) :: {:error, %{reason: binary()}}
  def log_error_message(level, code, error, metadata \\ [])

  def log_error_message(:error, code, error, metadata) do
    log_error(code, error, metadata)
    {:error, %{reason: error}}
  end

  def log_error_message(:warning, code, error, metadata) do
    log_warning(code, error, metadata)
    {:error, %{reason: error}}
  end
end
