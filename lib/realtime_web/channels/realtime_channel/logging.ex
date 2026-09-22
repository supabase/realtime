defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels
  """

  use Errata

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
    log(socket, :error, code, msg)
    {:error, %{reason: msg}}
  end

  @doc """
  Logs an Errata error at the error's own severity.

  The error's `code` becomes the `error_code`, so existing dashboards and alerts keep working, and
  the error's type, reason, context, cause and origin are attached as Logger metadata under the
  `:error` key instead of being flattened into the message. They are nested because the Logflare
  backend overwrites top-level `context`, `level` and `stacktrace` metadata with its own.
  """
  @spec log_error(socket :: Phoenix.Socket.t(), error :: Errata.error()) :: {:error, %{reason: binary}}
  def log_error(socket, error) when is_error(error) do
    code = Errata.code(error) || "UnknownErrorOnChannel"
    msg = build_msg(code, Errata.display_message(error) || Exception.message(error))
    log(socket, Errata.severity(error), code, msg, error_metadata(error))
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
  Logs an error if the log level is set to error.

  Accepts an optional `throttle: {max_count, window_ms}` option to limit
  how many times the log is emitted per tenant+code within the given time window.
  """
  @spec maybe_log_error(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any(), opts :: keyword()) ::
          {:error, %{reason: binary}}
  def maybe_log_error(socket, code, msg, opts \\ []), do: maybe_log(socket, :error, code, msg, opts)

  @doc """
  Logs a warning if the log level is set to warning.

  Accepts an optional `throttle: {max_count, window_ms}` option to limit
  how many times the log is emitted per tenant+code within the given time window.
  """
  @spec maybe_log_warning(socket :: Phoenix.Socket.t(), code :: binary(), msg :: any(), opts :: keyword()) ::
          {:error, %{reason: binary}}
  def maybe_log_warning(socket, code, msg, opts \\ []), do: maybe_log(socket, :warning, code, msg, opts)

  @doc """
  Logs an info if the log level is set to info.
  """
  @spec maybe_log_info(socket :: Phoenix.Socket.t(), msg :: any()) :: :ok
  def maybe_log_info(socket, msg), do: maybe_log(socket, :info, nil, msg, [])

  defp build_msg(nil, msg), do: stringify!(msg)
  defp build_msg(code, msg), do: "#{code}: #{stringify!(msg)}"

  defp log(%{assigns: assigns}, level, code, msg, metadata \\ []) do
    tenant = assigns.tenant
    Logger.metadata(external_id: tenant, project: tenant)
    enrich_metadata(level, Map.get(assigns, :access_token))
    Logger.log(level, msg, [error_code: code] ++ metadata)
    emit_telemetry(level, code, tenant)
  end

  @error_metadata_keys [:error_type, :reason, :context, :cause, :env]
  defp error_metadata(error), do: [error: Errata.to_map(error, only: @error_metadata_keys)]

  @error_levels [:error, :critical, :alert, :emergency]

  defp enrich_metadata(level, token) when level in [:warning | @error_levels],
    do: update_metadata_with_token_claims(token)

  defp enrich_metadata(_level, _token), do: :ok

  defp emit_telemetry(level, code, tenant) when level in @error_levels,
    do: Telemetry.execute([:realtime, :channel, :error], %{count: 1}, %{code: code, tenant: tenant})

  defp emit_telemetry(_level, _code, _tenant), do: :ok

  defp maybe_log(%{assigns: %{log_level: log_level}} = socket, level, code, msg, opts) do
    built_msg = build_msg(code, msg)
    if Logger.compare_levels(log_level, level) != :gt, do: do_log(socket, level, code, built_msg, opts)
    if level in [:error, :warning], do: {:error, %{reason: built_msg}}, else: :ok
  end

  defp do_log(socket, level, code, msg, []), do: log(socket, level, code, msg)

  defp do_log(%{assigns: %{tenant: tenant}} = socket, level, code, msg, throttle: {max_count, window_ms}) do
    key = {tenant, level, code}

    case Cachex.get(Realtime.LogThrottle, key) do
      {:ok, nil} ->
        Cachex.put(Realtime.LogThrottle, key, 1, expire: window_ms)
        log(socket, level, code, msg)

      {:ok, count} when count < max_count ->
        Cachex.incr(Realtime.LogThrottle, key)
        log(socket, level, code, msg)

      _ ->
        emit_telemetry(level, code, tenant)
    end
  end

  defp stringify!(msg) when is_binary(msg), do: msg
  defp stringify!(msg), do: inspect(msg, pretty: true)

  defp update_metadata_with_token_claims(nil), do: :ok

  defp update_metadata_with_token_claims(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} -> Logger.metadata(sub: claims["sub"], exp: claims["exp"], iss: claims["iss"])
      _ -> :ok
    end
  end
end
