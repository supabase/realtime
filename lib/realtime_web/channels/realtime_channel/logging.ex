defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels
  """

  alias Realtime.Telemetry
  require Logger

  @log_rate_table :log_rate_limiter
  @log_rate_default_max 10
  @log_rate_default_window_ms 300_000

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
  def log_error(socket, code, msg, opts \\ []) do
    msg = build_msg(code, msg)
    emit_system_error(:error, code)
    log(socket, :error, code, msg, opts)
    {:error, %{reason: msg}}
  end

  @doc """
  Logs a warning message
  """
  @spec log_warning(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any(), opts :: keyword()) ::
          {:error, %{reason: binary}}
  def log_warning(socket, code, msg, opts \\ []) do
    msg = build_msg(code, msg)
    log(socket, :warning, code, msg, opts)
    {:error, %{reason: msg}}
  end

  @doc """
  Logs an error if the log level is set to error
  """
  @spec maybe_log_error(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any(), opts :: keyword()) ::
          {:error, %{reason: binary}}
  def maybe_log_error(socket, code, msg, opts \\ []), do: maybe_log(socket, :error, code, msg, opts)

  @doc """
  Logs a warning if the log level is set to warning
  """
  @spec maybe_log_warning(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any(), opts :: keyword()) ::
          {:error, %{reason: binary}}
  def maybe_log_warning(socket, code, msg, opts \\ []), do: maybe_log(socket, :warning, code, msg, opts)

  @doc """
  Logs an info if the log level is set to info
  """
  @spec maybe_log_info(socket :: Phoenix.Socket.t(), msg :: any()) :: :ok
  def maybe_log_info(socket, msg), do: maybe_log(socket, :info, nil, msg, [])

  defp build_msg(code, msg) do
    msg = stringify!(msg)
    if code, do: "#{code}: #{msg}", else: msg
  end

  defp log(%{assigns: %{tenant: tenant, access_token: access_token}}, level, code, msg, opts) do
    unless rate_limited?(tenant, code, opts) do
      Logger.metadata(external_id: tenant, project: tenant)
      if level in [:error, :warning], do: update_metadata_with_token_claims(access_token)
      Logger.log(level, msg, error_code: code)
    end
  end

  defp maybe_log(%{assigns: %{log_level: log_level}} = socket, level, code, msg, opts) do
    msg = build_msg(code, msg)
    emit_system_error(level, code)
    if Logger.compare_levels(log_level, level) != :gt, do: log(socket, level, code, msg, opts)
    if level in [:error, :warning], do: {:error, %{reason: msg}}, else: :ok
  end

  defp rate_limited?(_tenant, nil, _opts), do: false

  defp rate_limited?(tenant, code, opts) do
    max = Keyword.get(opts, :max, @log_rate_default_max)
    window_ms = Keyword.get(opts, :window_ms, @log_rate_default_window_ms)
    key = {tenant, code}
    now = :erlang.monotonic_time(:millisecond)
    count = :ets.update_counter(@log_rate_table, key, {2, 1}, {key, 0, now})

    case :ets.lookup(@log_rate_table, key) do
      [{^key, ^count, window_start}] when now - window_start >= window_ms ->
        :ets.insert(@log_rate_table, {key, 1, now})
        false

      [{^key, ^count, _window_start}] ->
        count > max

      [] ->
        false
    end
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
end
