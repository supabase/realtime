defmodule RealtimeWeb.JwtVerificationTest do
  use ExUnit.Case, async: false

  alias RealtimeWeb.JwtVerification
  alias RealtimeWeb.Joken.CurrentTime.Mock

  @jwt_secret "secret"
  @alg "HS256"

  setup_all do
    Application.put_env(:realtime, :jwt_secret, @jwt_secret)
    Application.put_env(:realtime, :jwt_claim_validators, %{})
  end

  setup do
    {:ok, _pid} = start_supervised(Mock)
    :ok
  end

  test "verify/1 when token is not a string" do
    assert {:error, :not_a_string} = JwtVerification.verify([], @jwt_secret)
  end

  test "verify/1 when token has invalid format" do
    invalid_token = Base.encode64("{}")

    assert {:error, :expected_claims_map} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token header is not a map" do
    invalid_token =
      Base.encode64("[]") <> "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token claims is not a map" do
    invalid_token =
      Base.encode64("{}") <> "." <> Base.encode64("[]") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token header does not have typ or alg" do
    invalid_token =
      Base.encode64("{\"typ\": \"JWT\"}") <>
        "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)

    invalid_token =
      Base.encode64("{\"alg\": \"HS256\"}") <>
        "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token header alg is not allowed" do
    invalid_token =
      Base.encode64("{\"typ\": \"JWT\", \"alg\": \"ZZ999\"}") <>
        "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is HS256" do
    signer = Joken.Signer.create("HS256", @jwt_secret)

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is HS384" do
    signer = Joken.Signer.create("HS384", @jwt_secret)

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is HS512" do
    signer = Joken.Signer.create("HS512", @jwt_secret)

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token has expired" do
    signer = Joken.Signer.create(@alg, @jwt_secret)

    current_time = 1_610_086_801
    Mock.freeze(current_time)

    token =
      Joken.generate_and_sign!(
        %{
          "exp" => %Joken.Claim{generate: fn -> current_time end}
        },
        %{},
        signer
      )

    assert {:error, [message: "Invalid token", claim: "exp", claim_val: 1_610_086_801]} =
             JwtVerification.verify(token, @jwt_secret)

    token =
      Joken.generate_and_sign!(
        %{
          "exp" => %Joken.Claim{generate: fn -> current_time - 1 end}
        },
        %{},
        signer
      )

    assert {:error, [message: "Invalid token", claim: "exp", claim_val: 1_610_086_800]} =
             JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token has not expired" do
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

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token claims match expected claims from :jwt_claim_validators config" do
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

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token claims do not match expected claims from :jwt_claim_validators config" do
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
             JwtVerification.verify(token, @jwt_secret)
  end
end
