defmodule Realtime.Helpers do
  @moduledoc """
  This module includes helper functions for different contexts that can't be union in one module.
  """
  def encrypt(secret_key, text) do
    :crypto.crypto_one_time(:aes_128_ecb, secret_key, pad(text), true)
    |> Base.encode64()
  end

  def decrypt(secret_key, base64_text) do
    case Base.decode64(base64_text) do
      {:ok, crypto_text} ->
        :crypto.crypto_one_time(:aes_128_ecb, secret_key, crypto_text, false)
        |> unpad()

      _ ->
        :error
    end
  end

  defp pad(data) do
    to_add = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<to_add>>, to_add)
  end

  defp unpad(data) do
    to_remove = :binary.last(data)
    :binary.part(data, 0, byte_size(data) - to_remove)
  end

  def cancel_timer(nil), do: false
  def cancel_timer(ref), do: Process.cancel_timer(ref)
end
