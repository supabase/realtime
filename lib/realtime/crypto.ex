defmodule Realtime.Crypto do
  @moduledoc """
  Encrypt and decrypt operations required by Realtime.

  Supports AES-128-ECB (legacy) and AES-256-GCM. This is the only module that should know about
  the dual ECB/GCM column scheme (`jwt_secret`/`jwt_secret_gcm`, `settings`/`settings_gcm`) - other
  layers call `encrypt_jwt_secret!/1`, `decrypt_jwt_secret!/1`, `encrypt_settings!/2`, and
  `decrypt_settings!/2` and stay agnostic to which scheme is in play.

  Rollout status: writes dual-write both columns, `Realtime.Tenants.reconcile_encryption/1` backfills
  the GCM columns for existing tenants, and reads default to GCM with an ECB fallback for tenants the
  backfill has not reached yet. Once every tenant is migrated the legacy columns get wiped, at which
  point `encrypt!/1`, `decrypt!/1`, `decrypt_any!/1`, `migrate_to_gcm!/1` and the dual-write/dual-read
  helpers all go away.
  """

  @doc """
  Encrypts the given text using AES-128-ECB. Deprecated, use `encrypt_gcm!/1`.
  """
  @spec encrypt!(binary()) :: binary()
  def encrypt!(text) do
    secret_key = Application.get_env(:realtime, :db_enc_key)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, pad(text), true)
    |> Base.encode64()
  end

  @doc """
  Decrypts ciphertext produced by `encrypt!/1`.
  """
  @spec decrypt!(binary()) :: binary()
  def decrypt!(base64_text) do
    secret_key = Application.get_env(:realtime, :db_enc_key)
    crypto_text = Base.decode64!(base64_text)

    :aes_128_ecb
    |> :crypto.crypto_one_time(secret_key, crypto_text, false)
    |> unpad()
  end

  @doc """
  Encrypts the given text using AES-256-GCM with a random 12-byte IV per call.
  Result: `Base.encode64(iv <> tag <> ciphertext)`.
  """
  @spec encrypt_gcm!(binary()) :: binary()
  def encrypt_gcm!(text) do
    secret_key = Application.get_env(:realtime, :db_enc_key_gcm)
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, secret_key, iv, text, "", true)
    Base.encode64(iv <> tag <> ciphertext)
  end

  @doc """
  Decrypts ciphertext produced by `encrypt_gcm!/1`.
  """
  @spec decrypt_gcm!(binary()) :: binary()
  def decrypt_gcm!(base64_text) do
    secret_key = Application.get_env(:realtime, :db_enc_key_gcm)
    <<iv::binary-12, tag::binary-16, ciphertext::binary>> = Base.decode64!(base64_text)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, secret_key, iv, ciphertext, "", tag, false) do
      :error -> raise "GCM decryption failed: ciphertext or authentication tag is invalid"
      plaintext -> plaintext
    end
  end

  @doc """
  Decrypts ciphertext produced by either `encrypt_gcm!/1` or `encrypt!/1`, preferring GCM.

  For call sites that receive a ciphertext without knowing which column it came from. GCM's
  authentication tag makes the fallback deterministic: an ECB ciphertext has a ~2^-128 chance of
  passing GCM's tag check, so a successful GCM decrypt means the input really was GCM.

  Delete this along with `decrypt!/1` once the legacy columns are wiped.
  """
  @spec decrypt_any!(binary()) :: binary()
  def decrypt_any!(base64_text) do
    decrypt_gcm!(base64_text)
  rescue
    _ -> decrypt!(base64_text)
  end

  @doc """
  Decrypts a tenant's jwt_secret, preferring jwt_secret_gcm when present.
  """
  @spec decrypt_jwt_secret!(%{
          :jwt_secret_gcm => binary() | nil,
          :jwt_secret => binary() | nil,
          optional(any()) => any()
        }) :: binary()
  def decrypt_jwt_secret!(%{jwt_secret_gcm: jwt_secret_gcm}) when is_binary(jwt_secret_gcm),
    do: decrypt_gcm!(jwt_secret_gcm)

  def decrypt_jwt_secret!(%{jwt_secret: jwt_secret}), do: decrypt!(jwt_secret)

  @doc """
  Encrypts a plaintext jwt_secret with both schemes, for dual-writing jwt_secret and jwt_secret_gcm.
  """
  @spec encrypt_jwt_secret!(binary()) :: %{jwt_secret: binary(), jwt_secret_gcm: binary()}
  def encrypt_jwt_secret!(plaintext) do
    %{jwt_secret: encrypt!(plaintext), jwt_secret_gcm: encrypt_gcm!(plaintext)}
  end

  @doc """
  Decrypts the given keys of an extension's settings, preferring settings_gcm when present.
  """
  @spec decrypt_settings!(%{:settings_gcm => map() | nil, :settings => map(), optional(any()) => any()}, [
          String.t()
        ]) :: map()
  def decrypt_settings!(%{settings_gcm: settings_gcm}, keys) when is_map(settings_gcm),
    do: crypt_settings_fields(settings_gcm, keys, &decrypt_gcm!/1)

  def decrypt_settings!(%{settings: settings}, keys), do: crypt_settings_fields(settings, keys, &decrypt!/1)

  @doc """
  Encrypts the given keys of a settings map with both schemes, for dual-writing settings and settings_gcm.
  """
  @spec encrypt_settings!(map(), [String.t()]) :: %{settings: map(), settings_gcm: map()}
  def encrypt_settings!(settings, keys) do
    %{
      settings: crypt_settings_fields(settings, keys, &encrypt!/1),
      settings_gcm: crypt_settings_fields(settings, keys, &encrypt_gcm!/1)
    }
  end

  @doc """
  Re-encrypts a legacy AES-128-ECB ciphertext as AES-256-GCM, for backfilling jwt_secret_gcm.
  """
  @spec migrate_to_gcm!(binary()) :: binary()
  def migrate_to_gcm!(legacy_ciphertext), do: legacy_ciphertext |> decrypt!() |> encrypt_gcm!()

  @doc """
  Re-encrypts the given keys of a legacy AES-128-ECB settings map as AES-256-GCM, for backfilling settings_gcm.
  """
  @spec migrate_settings_to_gcm!(map(), [String.t()]) :: map()
  def migrate_settings_to_gcm!(settings, keys), do: crypt_settings_fields(settings, keys, &migrate_to_gcm!/1)

  defp crypt_settings_fields(settings, keys, crypt_fun) do
    Enum.reduce(keys, settings, fn key, acc ->
      case acc[key] do
        nil -> acc
        value -> Map.put(acc, key, crypt_fun.(value))
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
