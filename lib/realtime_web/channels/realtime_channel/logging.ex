defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels to ensure
  """
  use Realtime.Logs

  alias Realtime.Telemetry

  @doc """
  Logs messages according to user options given on config
  """
  def maybe_log_handle_info(
        %{assigns: %{log_level: log_level, channel_name: channel_name}} = socket,
        msg
      ) do
    if Logger.compare_levels(log_level, :info) == :eq do
      msg =
        case msg do
          msg when is_binary(msg) -> msg
          _ -> inspect(msg, pretty: true)
        end

      msg = "Received message on " <> channel_name <> " with payload: " <> msg
      Logger.log(log_level, msg)
    end

    socket
  end

  @doc """
  List of errors that are system triggered and not user driven
  """
  def system_errors,
    do: [
      "UnableToSetPolicies",
      "InitializingProjectConnection",
      "DatabaseConnectionIssue",
      "UnknownErrorOnChannel"
    ]

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
    if code in system_errors(), do: Telemetry.execute([:realtime, :channel, :error], %{code: code}, %{code: code})

    log_error(code, error, metadata)
    {:error, %{reason: error}}
  end

  def log_error_message(:warning, code, error, metadata) do
    log_warning(code, error, metadata)
    {:error, %{reason: error}}
  end
end
