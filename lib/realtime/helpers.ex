defmodule Realtime.Helpers do
  @moduledoc """
  This module includes helper functions for different contexts that can't be union in one module.
  """

  @spec cancel_timer(reference() | nil) :: non_neg_integer() | false | :ok | nil
  def cancel_timer(nil), do: nil
  def cancel_timer(ref), do: Process.cancel_timer(ref)

  def encrypt!(text, secret_key) do
    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, pad(text), true)
    |> Base.encode64()
  end

  def decrypt!(base64_text, secret_key) do
    crypto_text = Base.decode64!(base64_text)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, crypto_text, false)
    |> unpad()
  end

  @spec connect_db(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          list(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, pid} | {:error, Postgrex.Error.t() | term()}
  def connect_db(host, port, name, user, pass, socket_opts, pool \\ 5, queue_target \\ 5_000) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    host = decrypt!(host, secure_key)
    port = decrypt!(port, secure_key)
    name = decrypt!(name, secure_key)
    pass = decrypt!(pass, secure_key)
    user = decrypt!(user, secure_key)

    Postgrex.start_link(
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      pool_size: pool,
      queue_target: queue_target,
      parameters: [
        application_name: "supabase_realtime"
      ],
      socket_options: socket_opts
    )
  end

  @doc """
  Gets the external id from a host connection string found in the conn.

  ## Examples

      iex> Realtime.Helpers.get_external_id("tenant.realtime.supabase.co")
      {:ok, "tenant"}

      iex> Realtime.Helpers.get_external_id("tenant.supabase.co")
      {:ok, "tenant"}

      iex> Realtime.Helpers.get_external_id("www.supabase.co")
      {:error, :tenant_not_found_in_host}

  """

  @spec get_external_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_external_id(host) when is_binary(host) do
    case String.split(host, ".", parts: 2) do
      [] -> {:error, :tenant_not_found_in_host}
      [_] -> {:error, :tenant_not_found_in_host}
      ["www", _] -> {:error, :tenant_not_found_in_host}
      [id, _] -> {:ok, id}
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

  def decrypt_creds(host, port, name, user, pass) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    {
      decrypt!(host, secure_key),
      decrypt!(port, secure_key),
      decrypt!(name, secure_key),
      decrypt!(user, secure_key),
      decrypt!(pass, secure_key)
    }
  end
end
