defmodule RealtimeWeb.ChannelsAuthorizationTest do
  use ExUnit.Case, async: true

  use Mimic

  setup :set_mimic_from_context

  import Generators

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.JwtVerification

  @secret ""
  describe "authorize_conn/4" do
    test "when token is authorized" do
      input_token = "\n token %20 1 %20 2 %20 3   "
      expected_token = "token123"

      claims = %{"role" => "authenticated", "exp" => 1}

      expect(JwtVerification, :verify, 1, fn token, @secret, _jwks ->
        assert token == expected_token
        {:ok, claims}
      end)

      assert {:ok, ^claims} = ChannelsAuthorization.authorize_conn(input_token, @secret, nil, "tenant")
    end

    test "when token is unauthorized" do
      expect(JwtVerification, :verify, 1, fn _token, @secret, _jwks -> {:error, :signature_error} end)
      assert {:error, :signature_error} = ChannelsAuthorization.authorize_conn("bad_token", @secret, nil, "tenant")
    end

    test "when token is not a jwt token" do
      assert {:error, :token_malformed} = ChannelsAuthorization.authorize_conn("bad_token", @secret, nil, "tenant")
    end

    test "when token is not a string" do
      assert {:error, :invalid_token} = ChannelsAuthorization.authorize_conn([], @secret, nil, "tenant")
    end

    test "authorize_conn/4 fails when has missing headers" do
      jwt = generate_jwt_token(@secret, %{})

      assert {:error, :missing_claims} =
               ChannelsAuthorization.authorize_conn(jwt, @secret, nil, "tenant")
    end
  end

  describe "authorize_conn/4 with Vercel OIDC tokens" do
    @vercel_secret "vercel-oidc-test-secret-long-enough-for-hs256"
    @vercel_iss "https://integrations.vercel.com/oidc/oac_test"
    @tenant_ref "tenantref"

    defp token(claims) do
      claims = Map.merge(%{"role" => "service_role", "exp" => System.system_time(:second) + 1000}, claims)
      generate_jwt_token(@vercel_secret, claims)
    end

    test "accepts a Vercel token whose sub is the tenant project ref" do
      jwt = token(%{"iss" => @vercel_iss, "sub" => @tenant_ref})

      assert {:ok, %{"sub" => @tenant_ref}} =
               ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, @tenant_ref)
    end

    test "rejects a Vercel token whose sub is another project ref" do
      jwt = token(%{"iss" => @vercel_iss, "sub" => "otherref"})

      assert {:error, [message: "Invalid token", claim: "sub", claim_val: "otherref"]} =
               ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, @tenant_ref)
    end

    test "rejects a Vercel token without a sub" do
      jwt = token(%{"iss" => @vercel_iss})

      assert {:error, [message: "Invalid token", claim: "sub", claim_val: nil]} =
               ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, @tenant_ref)
    end

    test "rejects a Vercel token with an empty sub" do
      jwt = token(%{"iss" => @vercel_iss, "sub" => ""})

      assert {:error, [message: "Invalid token", claim: "sub", claim_val: ""]} =
               ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, @tenant_ref)
    end

    test "rejects a Vercel token when the tenant project ref is unknown" do
      jwt = token(%{"iss" => @vercel_iss, "sub" => @tenant_ref})

      assert {:error, [message: "Invalid token", claim: "sub", claim_val: @tenant_ref]} =
               ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, nil)
    end

    test "does not bind sub for tokens from other issuers" do
      user_id = "7f5f1f4e-1d3a-4c2b-9a8e-1b2c3d4e5f60"

      for claims <- [
            %{"iss" => "https://#{@tenant_ref}.supabase.co/auth/v1", "sub" => user_id},
            %{"iss" => "https://example.com/integrations.vercel.com/", "sub" => user_id},
            %{"sub" => user_id},
            %{}
          ] do
        jwt = token(claims)
        assert {:ok, _claims} = ChannelsAuthorization.authorize_conn(jwt, @vercel_secret, nil, @tenant_ref)
      end
    end
  end
end
