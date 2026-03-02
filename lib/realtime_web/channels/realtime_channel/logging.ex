defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels
  """

  alias Realtime.Telemetry
  require Logger

  defmacro __using__(_opts) do
    quote do
      require Logger
      import RealtimeWeb.RealtimeChannel.Logging
    end
  end

  @doc """
  Logs an error message
  """
  @spec log_error(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any()) ::
          {:error, %{reason: binary}}
  def log_error(socket, code, msg) do
    msg = build_msg(code, msg)
    emit_system_error(:error, code)
    log(socket, :error, code, msg)
    maybe_capture_sentry_error(socket, code, msg)
    {:error, %{reason: msg}}
  end

  @doc """
  Logs a warning message
  """
  @spec log_warning(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any()) ::
          {:error, %{reason: binary}}
  def log_warning(socket, code, msg) do
    msg = build_msg(code, msg)
    log(socket, :warning, code, msg)
    {:error, %{reason: msg}}
  end

  @doc """
  Logs an error if the log level is set to error
  """
  @spec maybe_log_error(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any()) :: {:error, %{reason: binary}}
  def maybe_log_error(socket, code, msg), do: maybe_log(socket, :error, code, msg)

  @doc """
  Logs a warning if the log level is set to warning
  """
  @spec maybe_log_warning(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any()) :: {:error, %{reason: binary}}
  def maybe_log_warning(socket, code, msg), do: maybe_log(socket, :warning, code, msg)

  @doc """
  Logs an info if the log level is set to info
  """
  @spec maybe_log_info(socket :: Phoenix.Socket.t(), msg :: any()) :: :ok
  def maybe_log_info(socket, msg), do: maybe_log(socket, :info, nil, msg)

  defp build_msg(code, msg) do
    msg = stringify!(msg)
    if code, do: "#{code}: #{msg}", else: msg
  end

  defp log(%{assigns: %{tenant: tenant, access_token: access_token}}, level, code, msg) do
    Logger.metadata(external_id: tenant, project: tenant)
    if level in [:error, :warning], do: update_metadata_with_token_claims(access_token)
    Logger.log(level, msg, error_code: code)
  end

  defp maybe_log(%{assigns: %{log_level: log_level}} = socket, level, code, msg) do
    msg = build_msg(code, msg)
    emit_system_error(level, code)
    if Logger.compare_levels(log_level, level) != :gt, do: log(socket, level, code, msg)
    if level == :error, do: maybe_capture_sentry_error(socket, code, msg)
    if level in [:error, :warning], do: {:error, %{reason: msg}}, else: :ok
  end

  @system_errors [
    "UnableToSetPolicies",
    "InitializingProjectConnection",
    "DatabaseConnectionIssue",
    "UnknownErrorOnChannel"
  ]

  def system_errors, do: @system_errors

  defp emit_system_error(:error, code) when code in @system_errors,
    do: Telemetry.execute([:realtime, :channel, :error], %{code: code}, %{code: code})

  defp emit_system_error(_, _), do: nil

  defp stringify!(msg) when is_binary(msg), do: msg
  defp stringify!(msg), do: inspect(msg, pretty: true)

  defp update_metadata_with_token_claims(nil), do: nil

  defp update_metadata_with_token_claims(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} ->
        sub = Map.get(claims, "sub")
        exp = Map.get(claims, "exp")
        iss = Map.get(claims, "iss")
        Logger.metadata(sub: sub, exp: exp, iss: iss)

      _ ->
        nil
    end
  end

  @sentry_capture_codes MapSet.new([
                         "MalformedWebSocketMessage",
                         "UnknownErrorOnChannel",
                         "InitializingProjectConnection",
                         "DatabaseConnectionIssue",
                         "UnableToSetPolicies"
                       ])

  defp maybe_capture_sentry_error(socket, code, msg) do
    if MapSet.member?(@sentry_capture_codes, code) and
         sampled?(Application.get_env(:realtime, :sentry_channel_error_sample_rate, 0.1)) do
      tenant = get_in(socket, [:assigns, :tenant])
      topic = Map.get(socket, :topic)

      Sentry.capture_message(msg,
        level: :error,
        tags: %{error_code: code, source: "channel"},
        extra: %{tenant: tenant, topic: topic}
      )
    end
  end

  defp sampled?(rate) when is_float(rate), do: rate >= 1.0 or :rand.uniform() <= rate
  defp sampled?(rate) when is_integer(rate), do: sampled?(rate / 1)
  defp sampled?(_), do: false
end
