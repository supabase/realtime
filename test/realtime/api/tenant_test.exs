defmodule Realtime.Api.TenantTest do
  use ExUnit.Case, async: true

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Extensions

  @settings %{
    "region" => "us-east-1",
    "db_host" => "127.0.0.1",
    "db_port" => "5432",
    "db_name" => "postgres",
    "db_user" => "postgres",
    "db_password" => "postgres"
  }

  describe "encrypt_jwt_secret/2 via changeset/3" do
    for cipher <- [:gcm, :ecb] do
      test "encrypts jwt_secret with the #{cipher} cipher when asked for it" do
        cipher = unquote(cipher)
        changeset = Tenant.changeset(%Tenant{}, %{external_id: "tenant", jwt_secret: "my-secret"}, cipher: cipher)
        jwt_secret = Ecto.Changeset.get_change(changeset, :jwt_secret)

        assert jwt_secret != "my-secret"
        assert Crypto.gcm?(jwt_secret) == (cipher == :gcm)
        assert Crypto.decrypt!(jwt_secret) == "my-secret"
      end
    end

    test "falls back to the legacy cipher when no cipher is given" do
      changeset = Tenant.changeset(%Tenant{}, %{external_id: "tenant", jwt_secret: "my-secret"})

      refute changeset |> Ecto.Changeset.get_change(:jwt_secret) |> Crypto.gcm?()
    end

    test "does nothing when jwt_secret is not part of the changes" do
      changeset = Tenant.changeset(%Tenant{}, %{external_id: "tenant", jwt_jwks: %{"keys" => []}})

      refute Ecto.Changeset.get_change(changeset, :jwt_secret)
    end

    test "leaves a cleared jwt_secret cleared" do
      tenant = %Tenant{external_id: "tenant", jwt_secret: "ciphertext"}
      changeset = Tenant.changeset(tenant, %{jwt_secret: nil, jwt_jwks: %{"keys" => []}})

      assert Ecto.Changeset.get_change(changeset, :jwt_secret) == nil
    end

    test "leaves jwt_secret unencrypted on an invalid changeset" do
      changeset = Tenant.changeset(%Tenant{}, %{jwt_secret: "my-secret"})

      refute changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :jwt_secret) == "my-secret"
    end
  end

  describe "mark_gcm_migrated/1" do
    test "stamps gcm_migrated_at when every encrypted value is on GCM" do
      changeset = tenant(jwt_secret: cipher_text(:gcm), extensions: [extension(:gcm)]) |> change() |> mark()

      assert {:ok, %DateTime{}} = stamp(changeset)
    end

    test "stamps a tenant that has nothing encrypted to migrate" do
      changeset = tenant(jwt_secret: nil, extensions: []) |> change() |> mark()

      assert {:ok, %DateTime{}} = stamp(changeset)
    end

    test "picks up the encrypted values the changeset is about to write, without a separate call" do
      attrs = %{
        external_id: "tenant",
        jwt_secret: "my-secret",
        extensions: [%{"type" => "postgres_cdc_rls", "settings" => @settings}]
      }

      changeset = Tenant.changeset(%Tenant{extensions: []}, attrs, cipher: :gcm)

      assert {:ok, %DateTime{}} = stamp(changeset)
    end

    test "does not stamp while jwt_secret is on the legacy cipher" do
      changeset = tenant(jwt_secret: cipher_text(:ecb), extensions: [extension(:gcm)]) |> change() |> mark()

      assert stamp(changeset) == :unchanged
    end

    test "does not stamp while an extension holds legacy settings" do
      changeset = tenant(jwt_secret: cipher_text(:gcm), extensions: [extension(:ecb)]) |> change() |> mark()

      assert stamp(changeset) == :unchanged
    end

    test "does not stamp when the extensions are not loaded, since they could still be legacy" do
      changeset = %Tenant{external_id: "tenant", jwt_secret: cipher_text(:gcm)} |> change() |> mark()

      assert stamp(changeset) == :unchanged
    end

    test "leaves an already stamped tenant alone" do
      changeset =
        tenant(jwt_secret: cipher_text(:gcm), extensions: [extension(:gcm)]) |> stamped() |> change() |> mark()

      assert stamp(changeset) == :unchanged
    end

    test "clears the stamp when the write puts jwt_secret back on the legacy cipher" do
      tenant = tenant(jwt_secret: cipher_text(:gcm), extensions: [extension(:gcm)]) |> stamped()
      changeset = Tenant.changeset(tenant, %{jwt_secret: "rotated"}, cipher: :ecb)

      assert stamp(changeset) == {:ok, nil}
    end

    test "clears the stamp when an extension is back on the legacy cipher" do
      changeset =
        tenant(jwt_secret: cipher_text(:gcm), extensions: [extension(:ecb)]) |> stamped() |> change() |> mark()

      assert stamp(changeset) == {:ok, nil}
    end

    test "does not clear the stamp when the extensions are not loaded" do
      changeset = %Tenant{external_id: "tenant", jwt_secret: cipher_text(:gcm)} |> stamped() |> change() |> mark()

      assert stamp(changeset) == :unchanged
    end

    test "is a no-op on an invalid changeset" do
      changeset = Tenant.changeset(%Tenant{}, %{jwt_secret: "my-secret"})

      refute changeset.valid?
      assert stamp(changeset) == :unchanged
    end
  end

  describe "gcm_migrated_at_changeset/2" do
    test "casts gcm_migrated_at and ignores every other field" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      changeset = Tenant.gcm_migrated_at_changeset(%Tenant{}, %{gcm_migrated_at: now, name: "should be ignored"})

      assert %Ecto.Changeset{valid?: true, changes: %{gcm_migrated_at: ^now} = changes} = changeset
      refute Map.has_key?(changes, :name)
    end

    test "requires gcm_migrated_at" do
      refute Tenant.gcm_migrated_at_changeset(%Tenant{}, %{}).valid?
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

  defp tenant(opts),
    do: %Tenant{external_id: "tenant", jwt_secret: opts[:jwt_secret], extensions: opts[:extensions]}

  defp extension(cipher),
    do: %Realtime.Api.Extensions{type: "postgres_cdc_rls", settings: encrypted_settings(cipher)}

  defp encrypted_settings(cipher) do
    for key <- Extensions.encrypted_settings_keys("postgres_cdc_rls"), reduce: @settings do
      acc -> Map.put(acc, key, Crypto.encrypt!(@settings[key], cipher: cipher))
    end
  end

  defp cipher_text(cipher), do: Crypto.encrypt!("a-secret", cipher: cipher)

  defp stamped(tenant), do: %{tenant | gcm_migrated_at: DateTime.utc_now(:second) |> DateTime.shift(day: -1)}

  defp change(tenant), do: Ecto.Changeset.change(tenant)

  defp mark(changeset), do: Tenant.mark_gcm_migrated(changeset)

  defp stamp(changeset) do
    if Ecto.Changeset.changed?(changeset, :gcm_migrated_at),
      do: {:ok, Ecto.Changeset.get_change(changeset, :gcm_migrated_at)},
      else: :unchanged
  end
end
