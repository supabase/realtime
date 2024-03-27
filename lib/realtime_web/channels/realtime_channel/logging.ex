defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels to ensure
  """
  require Logger

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
  def log_error_message(:warning, error) do
    error_msg = inspect(error)
    Logger.warn("Start channel error: " <> error_msg)
    {:error, %{reason: error_msg}}
  end

  def log_error_message(:error, error) do
    error_msg = inspect(error)
    Logger.error("Start channel error: " <> error_msg)
    {:error, %{reason: error_msg}}
  end
end
