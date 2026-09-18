defmodule Realtime.Tenants.Encryption do
  @moduledoc """
  Per-tenant rollout of the move from AES-128-ECB to AES-256-GCM.

  Both ciphers stay readable throughout: `Realtime.Crypto.decrypt!/1` picks one from the value
  itself, so a tenant can be moved either way without a deploy.

  Temporary: deleted along with `Realtime.Tenants.EncryptionReconciler` and the legacy branch in
  `Realtime.Crypto` once no tenant is left on ECB.
  """

  # TODO: delete this module once no tenant is left on AES-128-ECB.

  alias Realtime.Crypto
  alias Realtime.FeatureFlags

  @flag "gcm_encryption_backfill"

  @doc """
  Cipher a tenant's values should be written with: GCM only while `:db_enc_write_gcm` is set and the
  #{@flag} flag covers the tenant, the legacy cipher otherwise. Turning either off is enough to put
  the tenant back on ECB from its next write onwards.

  Reads the tenant cache, so it must not be called from inside that cache's fallback - see
  `Realtime.Tenants.EncryptionReconciler.reconcile/1`.
  """
  @spec cipher_for(binary() | nil) :: Crypto.cipher()
  def cipher_for(external_id) when is_binary(external_id) do
    if Crypto.write_gcm?() and FeatureFlags.enabled?(@flag, external_id), do: :gcm, else: :ecb
  end

  def cipher_for(_external_id), do: :ecb
end
