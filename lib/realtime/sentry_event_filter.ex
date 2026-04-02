defmodule Realtime.SentryEventFilter do
  @moduledoc false

  @redacted "[REDACTED]"
  @sensitive_headers ~w(authorization cookie x-api-key)
  @sensitive_keys ~w(access_token token api_key apikey jwt secret password)

  def before_send(event) when is_map(event) do
    event
    |> sanitize_request_headers()
    |> sanitize_extra()
  end

  def before_send(event), do: event

  defp sanitize_request_headers(event) do
    case Map.get(event, :request) do
      request when is_map(request) ->
        headers =
          case Map.get(request, :headers) do
            list when is_list(list) -> Enum.map(list, &sanitize_header/1)
            headers when is_map(headers) -> Map.new(headers, fn {key, value} -> {key, maybe_redact_header(key, value)} end)
            other -> other
          end

        Map.put(event, :request, Map.put(request, :headers, headers))

      _ ->
        event
    end
  end

  defp sanitize_extra(event) do
    case Map.get(event, :extra) do
      extra when is_map(extra) ->
        Map.put(event, :extra, Map.new(extra, fn {key, value} -> {key, maybe_redact_key(key, value)} end))

      _ ->
        event
    end
  end

  defp sanitize_header({key, value}), do: {key, maybe_redact_header(key, value)}
  defp sanitize_header(other), do: other

  defp maybe_redact_header(key, value) do
    if String.downcase(to_string(key)) in @sensitive_headers, do: @redacted, else: value
  end

  defp maybe_redact_key(key, value) do
    key = String.downcase(to_string(key))
    if Enum.any?(@sensitive_keys, &String.contains?(key, &1)), do: @redacted, else: value
  end
end
