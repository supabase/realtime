defmodule RealtimeWeb.JwtVerificationTest do
  use ExUnit.Case, async: false

  alias RealtimeWeb.JwtVerification
  alias RealtimeWeb.Joken.CurrentTime.Mock

  @jwt_secret "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxLDuvx4SeTr6KSwmXd3ZCwCGa8YW0lZMSv7sUa9IF3uKSm1d\nxzFWJEVknVjUUJneZHW4w13ooEzwxo84jlgeWWQiuaYmQejNXOFubRhvqxvvUMzX\njTTny8Ogirdhgokv7SlX/PqHMU5HA15BQ+lDqOCSGnkxv/NQp5BmCXNG2Tku3IA4\nRqQNUyWvjdwozkHXHPg/bq+wiBJyF+NS755k/Gn2dhTg3x3WSV5Ij9Jnl/kYHmRE\nxxuSqJpgYejP8CPl1X8xIZrIaUUuFH0IVdqo/ttuqR0ozyqI3q8PZpSZkL3/nPSg\nDBgNVSm1UuCQAHFMBJjPOiIPGnHBrY6/ndWJgQIDAQABAoIBAQCLWYscLhMKfqVD\nTDs2X3lo2QtjCambhXZx35/P024w7N6yEj/RYvvToLJC4+8v14N/CwRGrZ6lCz2+\nfzOjbXy6+j2756HNKkFsn24brqdWw+jOBwJj0WqzqzpvbLKRx94DmTn0Sg5D+WBI\nW5vDoFzGJax9QwXjJ2AqBxyzb09vj1ywQ823DFxHeUzDaCxItuFTkoPIpKR8WKTi\nAYKHM7z4gDQ3L3rXgkCnLxvDXrF4p1lI0252cK2K2Xj9cR9+mlFQNaZToQ3Mgio0\noBqGBnOo1pEs71FLaQe4/uvLgvpRtXu9ncPmAgrxuLOa0eyAjzF7GsWQkFuyNnpK\npqrfEoNRAoGBAOdKGsC3zonuEfw4lCrCL1oYlH0R3x9k+x3hWV/baWSiqrxZsZ/G\niArIxBAvFJOLt7hIGkUf4Ps6qaTSXHWHPUiV1Yf890ZCZNHB1yeoIMmpnEo95uNN\nlU7VaP0Ty18LYN5EnwGBBgJw6+BkJtgE7hHWvh6bPgmqker6g9emhL8VAoGBANm0\ni2wmtcfrEduRMokJ/4slWcFzsvsAwerLtiYWITqSiop/FQLgJ0Ibi7V2GqIl9H5g\nLd9VXklQ46wDUkHU83jqvNQR9OiAoFVQ9vFSxkj/rMu6/vghYtZqyG9vGApSunYW\nf/GtjA1lYczoTJvurcDL544MfsH/XogssafASFu9AoGAFywffgtsT/lgJ+rrPVVz\nNQ2dYuJ1fkm5twaq06XB62k4veImn6FeY+Y1boGpCBdJctcWerJ08fawpGjHBqdk\nBm+skxFPHOTuAO3wxnJbxpiNpgqJpWBSgzFycViYWY9kRyCM5bOtjHUPzM177syf\npX3kUmCvWHyUXfx3VRXD2vkCgYBNund5Es0eZuCGW24Gnao+nQRR3KRPl/KkiT0s\nlgQhLIcIcd0nnK6HnNwh2twhfpmvsVlPfuReGuJe3QS2eni/eFgZA5xEkwAr1e+F\nM/+VuquQReCY6Rqn4ZJUrv6PWQA3/0qJGGSDt+nWRi5sEii5SFQRVIbBbxLqXcLE\nWRO8pQKBgEe+LWpALZSM+hFTk3hJ503fxmP82kpWrwhS3z7cfNx3w0PkGIU7ipJd\nvYNcR0Pbhk7RvDW54J4SZQv1aI67mxk390u1hn8VQjpwJFZslJLDEhwlANLcSIeu\nkYE7IaJ4nya4gINVnLPZSMc8FYV7b7M4dlqIywB0PwzOgD9i+ezj\n-----END RSA PRIVATE KEY-----\n"
  @alg "RS256"

  setup_all do
    Application.put_env(:realtime, :jwt_signing_method, @alg)
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
      Base.encode64("{\"alg\": \"RS256\"}") <>
        "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token header alg is not allowed" do
    invalid_token =
      Base.encode64("{\"typ\": \"JWT\", \"alg\": \"ZZ999\"}") <>
        "." <> Base.encode64("{}") <> "." <> Base.encode64("<<\"sig\">>")

    assert {:error, _reason} = JwtVerification.verify(invalid_token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is RS256" do
    signer = Joken.Signer.create("RS256", %{"pem" => @jwt_secret})

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is RS384" do
    signer = Joken.Signer.create("RS384", %{"pem" => @jwt_secret})

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token is valid and alg is RS512" do
    signer = Joken.Signer.create("RS512", %{"pem" => @jwt_secret})

    token = Joken.generate_and_sign!(%{}, %{}, signer)

    assert {:ok, _claims} = JwtVerification.verify(token, @jwt_secret)
  end

  test "verify/1 when token has expired" do
    signer = Joken.Signer.create(@alg, %{"pem" => @jwt_secret})

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
    signer = Joken.Signer.create(@alg, %{"pem" => @jwt_secret})

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

    signer = Joken.Signer.create(@alg, %{"pem" => @jwt_secret})

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

    signer = Joken.Signer.create(@alg, %{"pem" => @jwt_secret})

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
