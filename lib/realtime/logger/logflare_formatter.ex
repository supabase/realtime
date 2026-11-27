defmodule Realtime.Logger.LogflareFormatter do
  @moduledoc """
  A `:logger` formatter that writes each log event as one line of JSON, in the
  payload shape that `LogflareLogger.HttpBackend` sends to Logflare.

  A log shipper such as Vector reads these lines from stdout and posts them to
  Logflare, so the Logflare source gets the same fields that the HTTP backend
  sends today.

  The formatter does the conversion that `Logger.Backends.Handler` does before
  it calls a Logger backend, then builds the payload with
  `LogflareLogger.LogParams.encode/4`. The conversion includes level names
  (`:warning` becomes `"warn"`), `module` and `function` from `mfa`, and the
  millisecond timestamp. A test compares the output of this formatter with
  the batch that the HTTP backend posts for the same log call.

  ## Options

  - `:truncate` - maximum message size in bytes. The default is the
    `:logger` application's `:truncate` value, the same limit that the
    backend uses.
  The formatter ignores the `:logger` application's `:utc_log` value.
  `LogParams.encode/4` always converts the timestamp from local time to UTC, so
  the formatter always gives it local time.
  """

  @behaviour :logger_formatter

  alias LogflareLogger.LogParams

  @impl true
  def check_config(config) when is_map(config), do: :ok
  def check_config(config), do: {:error, {:invalid_formatter_config, __MODULE__, config}}

  @impl true
  def format(%{level: erl_level, meta: meta} = event, config) do
    truncate = Map.get_lazy(config, :truncate, fn -> Application.get_env(:logger, :truncate, 8096) end)
    level = elixir_level(erl_level)
    message = Logger.Formatter.format_event(event, truncate)
    time = event_time(meta)
    date_time_ms = Logger.Formatter.system_time_to_date_time_ms(time, false)
    metadata = Map.merge(elixir_metadata(meta), %{erl_level: erl_level})

    payload =
      try do
        LogParams.encode(date_time_ms, level, message, metadata)
      rescue
        e -> formatter_error(e, level, message, date_time_ms, metadata)
      end

    [JSON.encode_to_iodata!(to_json(payload)), ?\n]
  end

  # Logger.Backends.Handler sends the system time when the event has no valid time
  defp event_time(%{time: time}) when is_integer(time) and time >= 0, do: time
  defp event_time(_), do: :os.system_time(:microsecond)

  # Same mapping as Logger.Backends.Handler, so Logflare keeps the level names
  # that the HTTP backend sends
  defp elixir_level(:warning), do: :warn
  defp elixir_level(level) when level in [:notice, :info], do: :info
  defp elixir_level(level) when level in [:debug, :all], do: :debug
  defp elixir_level(_), do: :error

  defp elixir_metadata(%{mfa: {mod, fun, arity}} = meta) do
    %{module: mod, function: "#{fun}/#{arity}"}
    |> Map.merge(meta)
    |> file_to_string()
  end

  defp elixir_metadata(meta), do: file_to_string(meta)

  defp file_to_string(%{file: file} = meta) when is_list(file), do: %{meta | file: List.to_string(file)}
  defp file_to_string(meta), do: meta

  # Same fallback event as LogflareLogger.Formatter.format/4
  defp formatter_error(e, level, message, date_time_ms, metadata) do
    %{
      "timestamp" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now(), :extended) <> "Z",
      "message" => "LogflareLogger formatter error: #{inspect(e, safe: true)}",
      "metadata" => %{
        "formatter_error_params" => %{
          "metadata" => inspect(metadata, safe: true, limit: :infinity, printable_limit: :infinity),
          "timestamp" => inspect(date_time_ms),
          "message" => inspect(message),
          "level" => inspect(level)
        },
        "level" => "error"
      }
    }
  end

  # LogParams.encode/4 leaves some terms as they are, because the HTTP backend
  # sends Erlang terms (BERT). JSON needs string keys, valid UTF-8 strings and
  # no references or ports.
  defp to_json(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp to_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {json_key(k), to_json(v)} end)
  end

  defp to_json(value) when is_list(value), do: Enum.map(value, &to_json/1)
  defp to_json(value) when is_tuple(value), do: value |> Tuple.to_list() |> to_json()
  defp to_json(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp to_json(value) when is_atom(value), do: Atom.to_string(value)
  defp to_json(value), do: inspect(value)

  defp json_key(key) when is_binary(key), do: to_json(key)
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)
end
