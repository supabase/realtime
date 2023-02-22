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

      iex> Realtime.Helpers.get_external_id("localhost")
      {:ok, "localhost"}

  """

  @spec get_external_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_external_id(host) when is_binary(host) do
    case String.split(host, ".", parts: 2) do
      [] -> {:error, :tenant_not_found_in_host}
      [id] -> {:ok, id}
      [id, _] -> {:ok, id}
    end
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

  def short_node_id() do
    fly_alloc_id = Application.get_env(:realtime, :fly_alloc_id)

    case String.split(fly_alloc_id, "-", parts: 2) do
      [short_alloc_id, _] -> short_alloc_id
      _ -> fly_alloc_id
    end
  end

  @doc """
  Gets a short node name from a node name when a node name looks like `realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2`

  ## Examples

      iex> node = Node.self()
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "nohost"

      iex> node = :"realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "83c3cfe3"

      iex> node = :"pink@127.0.0.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "127.0.0.1"

      iex> node = :"pink@10.0.1.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "10.0.1.1"

      iex> node = :"realtime@host.name.internal"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "host.name.internal"
  """

  @spec short_node_id_from_name(atom()) :: String.t()
  def short_node_id_from_name(name) when is_atom(name) do
    [_, host] = name |> Atom.to_string() |> String.split("@", parts: 2)

    case String.split(host, ":", parts: 8) do
      [_, _, _, _, _, one, two, _] ->
        one <> two

      _other ->
        host
    end
  end

  @doc """
  Takes the first N items from the queue and returns the list of items and the new queue.

  ## Examples

      iex> q = :queue.new()
      iex> q = :queue.in(1, q)
      iex> q = :queue.in(2, q)
      iex> q = :queue.in(3, q)
      iex> Realtime.Helpers.queue_take(q, 2)
      {[2, 1], {[], [3]}}
  """

  @spec queue_take(:queue.queue(), non_neg_integer()) :: {list(), :queue.queue()}
  def queue_take(q, count) do
    Enum.reduce_while(1..count, {[], q}, fn _, {items, queue} ->
      case :queue.out(queue) do
        {{:value, item}, new_q} ->
          {:cont, {[item | items], new_q}}

        {:empty, new_q} ->
          {:halt, {items, new_q}}
      end
    end)
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
