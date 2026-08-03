defmodule Realtime.CryptoTest do
  use ExUnit.Case, async: true

  alias Realtime.Crypto

  describe "encrypt!/1 and decrypt!/1 (legacy AES-128-ECB)" do
    test "round-trips a value" do
      assert Crypto.decrypt!(Crypto.encrypt!("my-super-secret-jwt-value")) == "my-super-secret-jwt-value"
    end
  end

  describe "encrypt_gcm!/1 and decrypt_gcm!/1 (AES-256-GCM)" do
    test "round-trips a value" do
      assert Crypto.decrypt_gcm!(Crypto.encrypt_gcm!("my-super-secret-jwt-value")) == "my-super-secret-jwt-value"
    end

    test "is non-deterministic - a fresh random IV is used every call" do
      refute Crypto.encrypt_gcm!("my-super-secret-jwt-value") == Crypto.encrypt_gcm!("my-super-secret-jwt-value")
    end

    test "tampering with the ciphertext or tag is rejected" do
      encoded = Crypto.encrypt_gcm!("my-super-secret-jwt-value")
      <<iv::binary-12, tag::binary-16, ciphertext::binary>> = Base.decode64!(encoded)
      tampered = Base.encode64(<<iv::binary, tag::binary, "x", ciphertext::binary>>)

      assert_raise RuntimeError, ~r/GCM decryption failed/, fn -> Crypto.decrypt_gcm!(tampered) end
    end
  end

  describe "decrypt_any!/1" do
    test "decrypts GCM ciphertext" do
      assert Crypto.decrypt_any!(Crypto.encrypt_gcm!("my-secret")) == "my-secret"
    end

    test "falls back to ECB for legacy ciphertext" do
      assert Crypto.decrypt_any!(Crypto.encrypt!("my-secret")) == "my-secret"
    end

    test "round-trips ECB ciphertext of every block-boundary length" do
      # The fallback relies on GCM's tag rejecting ECB blobs. Cover lengths that pad to 1, 2 and 3
      # blocks, including a value long enough to look like a plausible iv <> tag <> ciphertext frame.
      for length <- [1, 15, 16, 17, 28, 29, 31, 32, 33, 48] do
        plaintext = String.duplicate("a", length)
        assert Crypto.decrypt_any!(Crypto.encrypt!(plaintext)) == plaintext
      end
    end

    test "raises when the input is neither" do
      assert_raise ArgumentError, fn -> Crypto.decrypt_any!("not base64 at all !!!") end
    end
  end

  describe "decrypt_jwt_secret!/1" do
    test "prefers jwt_secret_gcm when present" do
      tenant = %{jwt_secret_gcm: Crypto.encrypt_gcm!("gcm-secret"), jwt_secret: Crypto.encrypt!("ecb-secret")}
      assert Crypto.decrypt_jwt_secret!(tenant) == "gcm-secret"
    end

    test "falls back to jwt_secret when jwt_secret_gcm is nil" do
      tenant = %{jwt_secret_gcm: nil, jwt_secret: Crypto.encrypt!("ecb-secret")}
      assert Crypto.decrypt_jwt_secret!(tenant) == "ecb-secret"
    end
  end

  describe "decrypt_settings!/2" do
    test "prefers settings_gcm when present, decrypting only the given keys" do
      extension = %{
        settings_gcm: %{"db_password" => Crypto.encrypt_gcm!("gcm-pass"), "region" => "us-east-1"},
        settings: %{"db_password" => Crypto.encrypt!("ecb-pass"), "region" => "us-east-1"}
      }

      settings = Crypto.decrypt_settings!(extension, ["db_password"])
      assert settings["db_password"] == "gcm-pass"
      assert settings["region"] == "us-east-1"
    end

    test "falls back to settings when settings_gcm is nil" do
      extension = %{settings_gcm: nil, settings: %{"db_password" => Crypto.encrypt!("ecb-pass")}}
      assert Crypto.decrypt_settings!(extension, ["db_password"]) == %{"db_password" => "ecb-pass"}
    end

    test "leaves keys absent from settings untouched" do
      extension = %{settings_gcm: nil, settings: %{"region" => "us-east-1"}}
      assert Crypto.decrypt_settings!(extension, ["db_password"]) == %{"region" => "us-east-1"}
    end
  end
end
