defmodule RealtimeWeb.JwtVerificationTest do
  # async: false due to mock usage and changing application env
  use Realtime.DataCase, async: false

  alias RealtimeWeb.JwtVerification
  alias RealtimeWeb.Joken.CurrentTime.Mock

  @jwt_secret "secret"
  @alg "HS256"

  setup_all do
    Application.put_env(:realtime, :jwt_secret, @jwt_secret)
    Application.put_env(:realtime, :jwt_claim_validators, %{})
    :ok
  end

  setup do
    start_supervised(Mock)
    on_exit(fn -> Application.put_env(:realtime, :jwt_claim_validators, %{}) end)
    :ok
  end

  describe "verify/3" do
    test "when token is not a string" do
      assert {:error, :not_a_string} = JwtVerification.verify([], @jwt_secret, nil)
    end

    test "when token is a badly formatted string fails" do
      invalid_token = "bad_token"

      assert {:error, :token_malformed} =
               JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token has invalid format fails" do
      invalid_token = Base.encode64("{}")

      assert {:error, :token_malformed} =
               JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token header is not a map" do
      invalid_token =
        Base.encode64("[]") <> "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

      assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token claims is not a map" do
      invalid_token =
        Base.encode64("{}") <> "." <> Base.encode64("[]") <> "." <> Base.encode64("<<\"sig\">>")

      assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token header does not have kid or alg" do
      invalid_token =
        Base.encode64(~s[{"kid": "mykid123"}]) <>
          "." <> Base.encode64("{}") <> "." <> Base.encode64(~s[<<"sig">>])

      assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret, nil)

      invalid_token =
        Base.encode64(~s[{"alg": "HS256"}]) <>
          "." <> Base.encode64("{}") <> "." <> Base.encode64(~s[<<"sig">>])

      assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token header alg is not allowed" do
      invalid_token =
        Base.encode64(~s[{"alg": "ZZ999"}]) <>
          "." <> Base.encode64("{}") <> "." <> Base.encode64(~s[<<"sig">>])

      assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret, nil)
    end

    test "when token is valid and alg is HS256" do
      signer = Joken.Signer.create("HS256", @jwt_secret)

      token = Joken.generate_and_sign!(%{}, %{}, signer)

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "when token is valid and alg is HS384" do
      signer = Joken.Signer.create("HS384", @jwt_secret)

      token = Joken.generate_and_sign!(%{}, %{}, signer)

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "when token is valid and alg is HS512" do
      signer = Joken.Signer.create("HS512", @jwt_secret)

      token = Joken.generate_and_sign!(%{}, %{}, signer)

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "when token has expired we return current time as the message so we can use it in expiration calculations" do
      signer = Joken.Signer.create(@alg, @jwt_secret)

      current_time = 1_610_086_801
      Mock.freeze(current_time)

      token =
        Joken.generate_and_sign!(
          %{"exp" => %Joken.Claim{generate: fn -> current_time end}},
          %{},
          signer
        )

      assert {:error, [message: current_time, claim: "exp", claim_val: 1_610_086_801]} =
               JwtVerification.verify(token, @jwt_secret, nil)

      assert is_integer(current_time)

      token =
        Joken.generate_and_sign!(
          %{"exp" => %Joken.Claim{generate: fn -> current_time - 1 end}},
          %{},
          signer
        )

      assert {:error, [message: current_time, claim: "exp", claim_val: _]} =
               JwtVerification.verify(token, @jwt_secret, nil)

      assert is_integer(current_time)
    end

    test "when token has not expired" do
      signer = Joken.Signer.create(@alg, @jwt_secret)

      Mock.freeze()
      current_time = Mock.current_time()

      token =
        Joken.generate_and_sign!(
          %{
            "exp" => %Joken.Claim{generate: fn -> current_time + 1 end}
          },
          %{},
          signer
        )

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "when token claims match expected claims from :jwt_claim_validators config" do
      Application.put_env(:realtime, :jwt_claim_validators, %{
        "iss" => "Tester",
        "aud" => "www.test.com"
      })

      signer = Joken.Signer.create(@alg, @jwt_secret)

      Mock.freeze()
      current_time = Mock.current_time()

      token =
        Joken.generate_and_sign!(
          %{
            "exp" => %Joken.Claim{generate: fn -> current_time + 1 end},
            "iss" => %Joken.Claim{generate: fn -> "Tester" end},
            "aud" => %Joken.Claim{generate: fn -> "www.test.com" end},
            "sub" => %Joken.Claim{generate: fn -> "tester@test.com" end}
          },
          %{},
          signer
        )

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "when token claims do not match expected claims from :jwt_claim_validators config" do
      Application.put_env(:realtime, :jwt_claim_validators, %{
        "iss" => "Issuer",
        "aud" => "www.test.com"
      })

      signer = Joken.Signer.create(@alg, @jwt_secret)

      Mock.freeze()
      current_time = Mock.current_time()

      token =
        Joken.generate_and_sign!(
          %{
            "exp" => %Joken.Claim{generate: fn -> current_time + 1 end},
            "iss" => %Joken.Claim{generate: fn -> "Tester" end},
            "aud" => %Joken.Claim{generate: fn -> "www.test.com" end},
            "sub" => %Joken.Claim{generate: fn -> "tester@test.com" end}
          },
          %{},
          signer
        )

      assert {:error, [message: "Invalid token", claim: "iss", claim_val: "Tester"]} =
               JwtVerification.verify(token, @jwt_secret, nil)
    end

    test "using RS256 JWK" do
      jwks = %{
        "keys" => [
          %{
            "kty" => "RSA",
            "n" =>
              "6r1mKwCalvJ0NyThyQkBr5huFILwwhXcxtsdlw-WybNz4avzODQwLFkA-b2fnnfdFgualV2NdcvoJSo1bzVGCWWqwWKWdTQKFjtcjAIC4FnhOv5ynNF9Ub-11ORDd1aiq_4XKNA4GaS1HqBekVDAAvJYy99Jz0CkLx4NU_VrS0U9sOQzUAhy2MwZCx2kZ3SWKEMjjEIkbvIb22IdRTyuFsAndKGpyzhw-MalnU5P2hOig-QApNBc0WJtTHTAa4PLQ6v_5jNc5PzCwP8jGK9SlrSF-GOnx9BVBX9t-AIDp-BviKbtY7y-pku6-f7HSiS2T3iAJkHXPm9E_NwwhWzMJQ",
            "e" => "AQAB",
            "kid" => "key-id-1"
          }
        ]
      }

      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfNnUI5w"

      # Check that the signature is valid even though time may be off.
      assert JwtVerification.verify(token, @jwt_secret, jwks) != {:error, :signature_error}
    end

    test "using RS256 JWK but wrong signature" do
      jwks = %{
        "keys" => [
          %{
            "kty" => "RSA",
            "n" =>
              "6r1mKwCalvJ0NyThyQkBr5huFILwwhXcxtsdlw-WybNz4avzODQwLFkA-b2fnnfdFgualV2NdcvoJSo1bzVGCWWqwWKWdTQKFjtcjAIC4FnhOv5ynNF9Ub-11ORDd1aiq_4XKNA4GaS1HqBekVDAAvJYy99Jz0CkLx4NU_VrS0U9sOQzUAhy2MwZCx2kZ3SWKEMjjEIkbvIb22IdRTyuFsAndKGpyzhw-MalnU5P2hOig-QApNBc0WJtTHTAa4PLQ6v_5jNc5PzCwP8jGK9SlrSF-GOnx9BVBX9t-AIDp-BviKbtY7y-pku6-f7HSiS2T3iAJkHXPm9E_NwwhWzMJQ",
            "e" => "AQAB",
            "kid" => "key-id-1"
          }
        ]
      }

      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfnnUI5w"

      assert JwtVerification.verify(token, @jwt_secret, jwks) == {:error, :signature_error}
    end

    test "using ES256 JWK" do
      jwks = %{
        "keys" => [
          %{
            "kty" => "EC",
            "x" => "iX_niXPSL2nW-9IyCELzyceAtuE3B98pWML5tQGACD4",
            "y" => "kT02DoLhXx6gtpkbrN8XwQ2wtzE6cDBaqlWgVXIeqV0",
            "crv" => "P-256",
            "d" => "FBVYnsYA2C3FTggEwV8kCRMo4FLl220_cWY2RdXyb_8",
            "kid" => "key-id-1"
          }
        ]
      }

      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDk2NTcsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MzI1N30.IIQBuEiSnZacGMqiqsrLAeRGOjIaB4F3x1gnLN5zvhFryJ-6tdgu96lFv5HUF13IL2UfHWad0OuvoDt4DEHRxw"

      # Check that the signature is valid even though time may be off.
      assert {:error, [message: _, claim: "exp", claim_val: _]} = JwtVerification.verify(token, @jwt_secret, jwks)
    end

    test "using ES256 JWK with wrong signature" do
      jwks = %{
        "keys" => [
          %{
            "kty" => "EC",
            "x" => "iX_niXPSL2nW-9IyCELzyceAtuE3B98pWML5tQGACD4",
            "y" => "kT02DoLhXx6gtpkbrN8XwQ2wtzE6cDBaqlWgVXIeqV0",
            "crv" => "P-256",
            "d" => "FBVYnsYA2C3FTggEwV8kCRMo4FLl220_cWY2RdXyb_8",
            "kid" => "key-id-1"
          }
        ]
      }

      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDk2NTcsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MzI1N30.IIQBuEiSnZacGMqiqsrLAeRGOjIaB4F3x1gnLN5zvhFryJ-6tdgu96lFv5HUF13IL2UfHWad0OuvoDt4DEHrxw"

      assert JwtVerification.verify(token, @jwt_secret, jwks) == {:error, :signature_error}
    end

    test "using HS256 JWK" do
      jwks = %{
        "keys" => [
          %{
            "alg" => "HS256",
            "k" =>
              "WWpiUEVXK2I4dVM1djkzMS9TWTNmb2RtcUtiZVh3NnBHS0JaS1JDMGpaODdhVHpaZ3N0Ly9yMG0wU1M4Z1U4OFE0aGdwclBMMzVRRU5ya253TWxhUlE9PQ",
            "key_ops" => ["verify"],
            "kid" => "4FcGwlBxkBV1bSZw",
            "kty" => "oct"
          }
        ]
      }

      token =
        "eyJhbGciOiJIUzI1NiIsImtpZCI6IjRGY0d3bEJ4a0JWMWJTWnciLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2hqbmRnYWdpZGlwY3RxdXFxeXloLnN1cGFiYXNlLmNvL2F1dGgvdjEiLCJzdWIiOiJmZjA0NjVlMy1lZjk3LTRkYjItOWE1Zi0zZDI4Y2YxODE0MmYiLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwiZXhwIjoxNzUyODA4NjE4LCJpYXQiOjE3NTI4MDUwMTgsImVtYWlsIjoiY2hhdEBlZHVhcmRvLmd1cmdlbC5tZSIsInBob25lIjoiIiwiYXBwX21ldGFkYXRhIjp7InByb3ZpZGVyIjoiZW1haWwiLCJwcm92aWRlcnMiOlsiZW1haWwiXX0sInVzZXJfbWV0YWRhdGEiOnsiZW1haWwiOiJjaGF0QGVkdWFyZG8uZ3VyZ2VsLm1lIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsInBob25lX3ZlcmlmaWVkIjpmYWxzZSwic3ViIjoiZmYwNDY1ZTMtZWY5Ny00ZGIyLTlhNWYtM2QyOGNmMTgxNDJmIn0sInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiYWFsIjoiYWFsMSIsImFtciI6W3sibWV0aG9kIjoicGFzc3dvcmQiLCJ0aW1lc3RhbXAiOjE3NTI4MDUwMTh9XSwic2Vzc2lvbl9pZCI6IjA2MDJkYWM0LWMwMjctNGIwNi1hZDM5LTMzN2ViMTZlODdlNSIsImlzX2Fub255bW91cyI6ZmFsc2V9.SnGzRjLfHPtT64kXYEQVBLKizCl76LqEPILyAPxoDwk"

      # Check that the signature is valid even though time may be off.
      assert {:error, [message: _, claim: "exp", claim_val: _]} = JwtVerification.verify(token, @jwt_secret, jwks)
    end

    test "using JWT without typ header parameter" do
      jwks = %{
        "keys" => [
          %{
            "alg" => "RS256",
            "e" => "AQAB",
            "kid" => "sso_oidc_key_pair_01K20X7J43ZV31EKZMG7X3KW7K",
            "kty" => "RSA",
            "n" =>
              "uyc8QVrMjJTZEZoGNIJrugvf6j3iZ2Uz2IEgFuHCeC5AbM4BwZ4V1JshcW2CRs8uAmEdnH_-jiibayGmoND7OLziZJZsLir_8_kZSc5jjJ-IVFMzB1XXKze44HB3IOpcaPW1IOx0NfSI6-xOFinX7yApTZxXxmLFMEXtOWVsY_MPMrjThfvCSqesDGLRGKCn_DA4Hhaixf4NG-etGUOiavHNpqfREM7td-9caWpIyo7acWcgfYyhkxZbuYRINje1V66HWIdzzZ8uhfLXm-85LZdaWn9J83OHh3TEQW2SIAfHSNZkwXu6h5ndd_ciWxTWuvU3yjWkS-k4C8dXB--bZQ",
            "use" => "sig",
            "x5t#S256" => "HmlJQWnNuujjOdcRTCu5amk1pttdFRMBR7Rl4zplobA"
          }
        ]
      }

      token =
        "eyJhbGciOiJSUzI1NiIsImtpZCI6InNzb19vaWRjX2tleV9wYWlyXzAxSzIwWDdKNDNaVjMxRUtaTUc3WDNLVzdLIn0.eyJyb2xlIjoiYXV0aGVudGljYXRlZCIsImlzcyI6Imh0dHBzOi8vYXBpLndvcmtvcy5jb20vdXNlcl9tYW5hZ2VtZW50L2NsaWVudF8wMUsyMFg3SkNROVg1NDVXUzgwUVpQQTNGUSIsInN1YiI6InVzZXJfMDFLMjBYR1g3SkU1M1JNVEIzRjE0SEFUNTkiLCJzaWQiOiJzZXNzaW9uXzAxSzIwWEdYQVhINjhLMkI0VjcwWko3VzlZIiwianRpIjoiMDFLMjEyUzNLMEpXQ0U3Wk1URVk0RVM4UTYiLCJleHAiOjE3NTQ1MzA5MTQsImlhdCI6MTc1NDUzMDYxNH0.kt-zlPxaLVDMU9iAWCYvi3dtm9HzYponaX5E4lsS2k5F469obf4i9FyLDeXsaPyAN9V3DaAjUwys9lDyjiPsE7y1s2tFE1g9LU4goJbwinkoklUYrTmVVZcY4lkVEQSZZGwmkwgIsqKsdwTlYMzVjejsAk25Foq-FhGdsyoju21sU5S4fZPC-n8Rl8wBwD5rOPFWVHxk3z4z37585LDHhADyq1S17WxLJobfEgK_TeAlwXa2bK14vutVPpuL-qAn8nX8b6aqBoHtvRbfqsi2s72bA1S31rTgT2hgD5hqbn_g0rVmMJXt2u1zl4XDBzUj_c3lxNncUf1MgsVOHrbYRw"

      assert {:error, [message: _, claim: "exp", claim_val: _]} = JwtVerification.verify(token, @jwt_secret, jwks)
    end

    test "using HS256 JWK with wrong signature" do
      jwks = %{
        "keys" => [
          %{
            "alg" => "HS256",
            "k" =>
              "WWpiUEVXK2I4dVM1djkzMS9TWTNmb2RtcUtiZVh3NnBHS0JaS1JDMGpaODdhVHpaZ3N0Ly9yMG0wU1M4Z1U4OFE0aGdwclBMMzVRRU5ya253TWxhUlE9PQ",
            "key_ops" => ["verify"],
            "kid" => "4FcGwlBxkBV1bSZw",
            "kty" => "oct"
          }
        ]
      }

      token =
        "eyJhbGciOiJIUzI1NiIsImtpZCI6IjRGY0d3bEJ4a0JWMWJTWnciLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2hqbmRnYWdpZGlwY3RxdXFxeXloLnN1cGFiYXNlLmNvL2F1dGgvdjEiLCJzdWIiOiJmZjA0NjVlMy1lZjk3LTRkYjItOWE1Zi0zZDI4Y2YxODE0MmYiLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwiZXhwIjoxNzUyODA4NjE4LCJpYXQiOjE3NTI4MDUwMTgsImVtYWlsIjoiY2hhdEBlZHVhcmRvLmd1cmdlbC5tZSIsInBob25lIjoiIiwiYXBwX21ldGFkYXRhIjp7InByb3ZpZGVyIjoiZW1haWwiLCJwcm92aWRlcnMiOlsiZW1haWwiXX0sInVzZXJfbWV0YWRhdGEiOnsiZW1haWwiOiJjaGF0QGVkdWFyZG8uZ3VyZ2VsLm1lIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsInBob25lX3ZlcmlmaWVkIjpmYWxzZSwic3ViIjoiZmYwNDY1ZTMtZWY5Ny00ZGIyLTlhNWYtM2QyOGNmMTgxNDJmIn0sInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiYWFsIjoiYWFsMSIsImFtciI6W3sibWV0aG9kIjoicGFzc3dvcmQiLCJ0aW1lc3RhbXAiOjE3NTI4MDUwMTh9XSwic2Vzc2lvbl9pZCI6IjA2MDJkYWM0LWMwMjctNGIwNi1hZDM5LTMzN2ViMTZlODdlNSIsImlzX2Fub255bW91cyI6ZmFsc2V9.SnGzRjLfHPtT64kXYEQVBLKizCl76LqEPILyApxoDwk"

      assert JwtVerification.verify(token, @jwt_secret, jwks) == {:error, :signature_error}
    end

    test "returns error when no matching JWK is found for RSA algorithm" do
      # Replace with a valid JWT structure
      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfNnUI5w"

      jwt_secret = "secret"
      jwks = %{"keys" => [%{"kty" => "RSA", "kid" => "some_other_kid"}]}

      assert {:error, :error_generating_signer} = JwtVerification.verify(token, jwt_secret, jwks)
    end

    test "returns error when no matching JWK is found for EC algorithm" do
      # Replace with a valid JWT structure
      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfNnUI5w"

      jwt_secret = "secret"
      jwks = %{"keys" => [%{"kty" => "EC", "kid" => "some_other_kid"}]}

      assert {:error, :error_generating_signer} = JwtVerification.verify(token, jwt_secret, jwks)
    end

    test "returns error when no matching JWK is found for OKP algorithm" do
      # Replace with a valid JWT structure
      token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfNnUI5w"

      jwt_secret = "secret"
      jwks = %{"keys" => [%{"kty" => "OKP", "kid" => "some_other_kid"}]}

      assert {:error, :error_generating_signer} = JwtVerification.verify(token, jwt_secret, jwks)
    end

    test "using Ed25519 JWK" do
      # Generate Ed25519 key pair
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      jwk = %{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "x" => Base.url_encode64(pub, padding: false),
        "d" => Base.url_encode64(priv, padding: false),
        "kid" => "ed-key-1"
      }

      jwks = %{"keys" => [jwk]}

      signer = Joken.Signer.create("Ed25519", jwk, %{"kid" => "ed-key-1"})

      Mock.freeze()
      current_time = Mock.current_time()

      token =
        Joken.generate_and_sign!(
          %{"exp" => %Joken.Claim{generate: fn -> current_time + 100 end}},
          %{},
          signer
        )

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, jwks)
    end

    test "returns error for unsupported algorithm with kid and jwks" do
      header = Base.url_encode64(Jason.encode!(%{"alg" => "PS256", "kid" => "key-1"}), padding: false)
      claims = Base.url_encode64(Jason.encode!(%{"exp" => 9_999_999_999}), padding: false)
      token = "#{header}.#{claims}.signature"

      jwks = %{"keys" => [%{"kty" => "RSA", "kid" => "key-1"}]}

      assert {:error, _} = JwtVerification.verify(token, @jwt_secret, jwks)
    end

    test "falls back to jwt_secret when HS256 kid has no matching JWK" do
      Mock.freeze()
      current_time = Mock.current_time()

      signer = Joken.Signer.create("HS256", @jwt_secret)

      token =
        Joken.generate_and_sign!(
          %{"exp" => %Joken.Claim{generate: fn -> current_time + 100 end}},
          %{},
          signer
        )

      jwks = %{"keys" => [%{"kty" => "oct", "kid" => "wrong-kid"}]}

      assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret, jwks)
    end
  end
end
