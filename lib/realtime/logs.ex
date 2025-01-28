defmodule Realtime.Logs do
  @moduledoc """
  Logging operations for Realtime
  """
  require Logger

  @doc """
  Prepares a value to be logged
  """
  def to_log(value) when is_binary(value), do: value
  def to_log(value), do: inspect(value, pretty: true)

  @doc """
  Logs error with a given Operational Code
  """
  @spec log_error(String.t(), any(), keyword()) :: :ok
  def log_error(code, error, metadata \\ []) do
    Logger.error("#{code}: #{to_log(error)}", [error_code: code] ++ metadata)
  end

  @doc """
  Logs warning with a given Operational Code
  """
  @spec log_error(String.t(), any(), keyword()) :: :ok
  def log_warning(code, warning, metadata \\ []) do
    Logger.warning("#{code}: #{to_log(warning)}", [{:error_code, code} | metadata])
  end
end

defimpl Jason.Encoder, for: DBConnection.ConnectionError do
  def encode(
        %DBConnection.ConnectionError{message: message, reason: reason, severity: severity},
        _opts
      ) do
    inspect(%{message: message, reason: reason, severity: severity}, pretty: true)
  end
end

defimpl Jason.Encoder, for: Postgrex.Error do
  def encode(
        %Postgrex.Error{
          message: message,
          postgres: %{code: code, schema: schema, table: table}
        },
        _opts
      ) do
    inspect(%{message: message, schema: schema, table: table, code: code}, pretty: true)
  end
end
