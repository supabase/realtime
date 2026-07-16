defmodule RealtimeWeb.ApiJwtVerificationTest do
  use ExUnit.Case, async: false

  import Generators, only: [generate_api_jwt_keys: 1, generate_api_jwt_token: 2]

  alias Realtime.ApiJwt.Jwks
  alias Realtime.ApiJwt.Validator
  alias RealtimeWeb.ApiJwtVerification

  @jwks_url "https://platform.example/.well-known/jwks.json"
  @issuer "https://platform.example"

  setup do
    {signer, jwks} = generate_api_jwt_keys("api-jwt-kid")

    validator = %Validator{
      jwks_url: @jwks_url,
      issuer: @issuer,
      audiences: ["realtime"],
      subjects: ["platform-service"]
    }

    previous = Application.get_env(:realtime, :api_jwt_validators)
    previous_req = Application.get_env(:realtime, :api_jwt_jwks_req_options)

    Application.put_env(:realtime, :api_jwt_validators, [validator])
    Application.put_env(:realtime, :api_jwt_jwks_req_options, plug: {Req.Test, Jwks})
    Cachex.clear(Jwks)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Jwks, fn conn -> Req.Test.json(conn, jwks) end)

    on_exit(fn ->
      Application.put_env(:realtime, :api_jwt_validators, previous)

      if previous_req,
        do: Application.put_env(:realtime, :api_jwt_jwks_req_options, previous_req),
        else: Application.delete_env(:realtime, :api_jwt_jwks_req_options)

      Cachex.clear(Jwks)
    end)

    %{signer: signer, jwks: jwks}
  end

  test "verifies a valid token", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{})
    assert {:ok, claims} = ApiJwtVerification.verify(token)
    assert claims["iss"] == @issuer
    assert claims["sub"] == "platform-service"
  end

  test "accepts a list-valued aud when one entry matches", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{"aud" => ["other", "realtime"]})
    assert {:ok, _claims} = ApiJwtVerification.verify(token)
  end

  test "rejects an unknown issuer", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{"iss" => "https://evil.example"})
    assert {:error, :no_matching_validator} = ApiJwtVerification.verify(token)
  end

  test "rejects a wrong audience", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{"aud" => "someone-else"})
    assert {:error, _} = ApiJwtVerification.verify(token)
  end

  test "rejects a wrong subject", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{"sub" => "attacker"})
    assert {:error, _} = ApiJwtVerification.verify(token)
  end

  test "rejects an expired token", %{signer: signer} do
    token = generate_api_jwt_token(signer, %{"exp" => Joken.current_time() - 10})
    assert {:error, _} = ApiJwtVerification.verify(token)
  end

  test "rejects a token whose kid is not in the JWKS", %{jwks: jwks} do
    {other_signer, _other_jwks} = generate_api_jwt_keys("unknown-kid")
    # keep serving the original JWKS (without unknown-kid) even after refresh
    Req.Test.stub(Jwks, fn conn -> Req.Test.json(conn, jwks) end)
    token = generate_api_jwt_token(other_signer, %{})
    assert {:error, :error_generating_signer} = ApiJwtVerification.verify(token)
  end

  test "rejects an HS-signed token even when its alg is not allowed" do
    signer = Joken.Signer.create("HS256", "platform-service")

    token =
      Joken.generate_and_sign!(
        %{},
        %{"iss" => @issuer, "aud" => "realtime", "sub" => "platform-service", "exp" => Joken.current_time() + 100},
        signer
      )

    assert {:error, :alg_not_allowed} = ApiJwtVerification.verify(token)
  end

  test "rejects a non-string token" do
    assert {:error, :not_a_string} = ApiJwtVerification.verify(nil)
  end
end
