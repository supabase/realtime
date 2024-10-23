defmodule Realtime.Tenants.Connect.Piper do
  @moduledoc """
  Pipes different commands to execute specific actions during the connection process.
  """
  @callback run(any()) :: {:ok, any()} | {:error, any()}

  def run(pipers, init) do
    Enum.reduce_while(pipers, {:ok, init}, fn piper, {:ok, acc} ->
      case piper.run(acc) do
        {:ok, result} ->
          {:cont, {:ok, result}}

        {:error, error} ->
          {:halt, {:error, error}}

        _e ->
          raise ArgumentError, "must return {:ok, _} or {:error, _}"
      end
    end)
  end
end
