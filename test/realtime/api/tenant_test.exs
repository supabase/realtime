defmodule Realtime.Api.TenantTest do
  use ExUnit.Case, async: true

  alias Realtime.Api.Tenant
  alias Realtime.Crypto

  describe "encrypt_jwt_secret/1 via changeset/2" do
    test "dual-writes jwt_secret (ECB) and jwt_secret_gcm (GCM) from the same plaintext" do
      changeset = Tenant.changeset(%Tenant{}, %{external_id: "tenant", jwt_secret: "my-secret"})

      jwt_secret = Ecto.Changeset.get_change(changeset, :jwt_secret)
      jwt_secret_gcm = Ecto.Changeset.get_change(changeset, :jwt_secret_gcm)

      assert jwt_secret != "my-secret"
      assert jwt_secret_gcm != "my-secret"
      assert Crypto.decrypt!(jwt_secret) == "my-secret"
      assert Crypto.decrypt_gcm!(jwt_secret_gcm) == "my-secret"
    end

    test "does nothing when jwt_secret is not part of the changes" do
      changeset = Tenant.changeset(%Tenant{}, %{external_id: "tenant", jwt_jwks: %{"keys" => []}})

      refute Ecto.Changeset.get_change(changeset, :jwt_secret)
      refute Ecto.Changeset.get_change(changeset, :jwt_secret_gcm)
    end

    test "clears jwt_secret_gcm when jwt_secret is cleared" do
      tenant = %Tenant{external_id: "tenant", jwt_secret: "ecb-ciphertext", jwt_secret_gcm: "gcm-ciphertext"}
      changeset = Tenant.changeset(tenant, %{jwt_secret: nil, jwt_jwks: %{"keys" => []}})

      assert Ecto.Changeset.get_change(changeset, :jwt_secret) == nil
      assert Ecto.Changeset.get_field(changeset, :jwt_secret_gcm) == nil
    end

    test "does nothing on an invalid changeset" do
      changeset = Tenant.changeset(%Tenant{}, %{jwt_secret: "my-secret"})

      refute changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :jwt_secret_gcm)
    end
  end

  describe "reconcile_encryption_changeset/2" do
    test "only accepts and requires jwt_secret_gcm" do
      changeset =
        Tenant.reconcile_encryption_changeset(%Tenant{}, %{jwt_secret_gcm: "ciphertext", name: "should be ignored"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :jwt_secret_gcm) == "ciphertext"
      refute Ecto.Changeset.get_change(changeset, :name)

      refute Tenant.reconcile_encryption_changeset(%Tenant{}, %{}).valid?
    end
  end

  describe "changeset/2 legacy extension type normalization" do
    test ~s(remaps a legacy "postgres" extension type to "postgres_cdc_rls") do
      attrs = %{
        external_id: "tenant",
        jwt_secret: "my-secret",
        extensions: [%{"type" => "postgres", "settings" => %{"region" => "us-east-1"}}]
      }

      changeset = Tenant.changeset(%Tenant{}, attrs)
      [extension_changeset] = Ecto.Changeset.get_change(changeset, :extensions)

      assert Ecto.Changeset.get_change(extension_changeset, :type) == "postgres_cdc_rls"
    end
  end

  describe "maybe_set_default/3" do
    test "keeps the changeset unchanged when the property already has a value" do
      changeset = Ecto.Changeset.change(%Tenant{max_bytes_per_second: 12_345})
      result = Tenant.maybe_set_default(changeset, :max_bytes_per_second, :tenant_max_bytes_per_second)

      refute Ecto.Changeset.get_change(result, :max_bytes_per_second)
    end
  end
end
