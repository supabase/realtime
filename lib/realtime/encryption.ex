defmodule Realtime.Crypto do
  @moduledoc """
  Encrypt and decrypt operations required by Realtime. It uses the secret set on Application.get_env(:realtime, :db_enc_key)
  """

  @doc """
  Encrypts the given text
  """
  @spec encrypt!(binary()) :: binary()
  def encrypt!(text) do
    secret_key = Application.get_env(:realtime, :db_enc_key)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, pad(text), true)
    |> Base.encode64()
  end

  @doc """
  Decrypts the given base64 encoded text
  """
  @spec decrypt!(binary()) :: binary()
  def decrypt!(base64_text) do
    secret_key = Application.get_env(:realtime, :db_enc_key)
    crypto_text = Base.decode64!(base64_text)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, crypto_text, false)
    |> unpad()
  end

  @doc "
  Decrypts the given credentials
  "
  @spec decrypt_creds(binary(), binary(), binary(), binary(), binary()) ::
          {binary(), binary(), binary(), binary(), binary()}
  def decrypt_creds(host, port, name, user, pass) do
    {
      decrypt!(host),
      decrypt!(port),
      decrypt!(name),
      decrypt!(user),
      decrypt!(pass)
    }
  end

  defp pad(data) do
    to_add = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<to_add>>, to_add)
  end

  defp unpad(data) do
    to_remove = :binary.last(data)
    :binary.part(data, 0, byte_size(data) - to_remove)
  end
end
