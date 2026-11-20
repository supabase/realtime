defmodule RealtimeWeb.ChannelsAuthorization do
  @moduledoc """
  Check connection is authorized to access channel
  """

  @vercel_oidc_issuer_prefix "https://integrations.vercel.com/"

  @spec authorize(binary(), binary() | nil, binary() | nil) ::
          {:ok, map()} | {:error, any()} | {:error, :expired_token, String.t()}
  defp authorize(token, jwt_secret, jwt_jwks) when is_binary(token) do
    token
    |> clean_token()
    |> RealtimeWeb.JwtVerification.verify(jwt_secret, jwt_jwks)
  end

  defp authorize(_token, _jwt_secret, _jwt_jwks), do: {:error, :invalid_token}

  @doc """
  Authorize connection to access channel
  """
  def authorize_conn(token, jwt_secret, jwt_jwks, tenant_external_id) do
    case authorize(token, jwt_secret, jwt_jwks) do
      {:ok, claims} ->
        required = ["role", "exp"]
        claims_keys = Map.keys(claims)

        if Enum.all?(required, &(&1 in claims_keys)),
          do: check_vercel_subject(claims, tenant_external_id),
          else: {:error, :missing_claims}

      {:error, [message: validation_timer, claim: "exp", claim_val: claim_val]}
      when is_integer(validation_timer) and is_integer(claim_val) ->
        msg = "Token has expired #{validation_timer - claim_val} seconds ago"
        {:error, :expired_token, msg}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Vercel Marketplace OIDC tokens are signed with one key shared by every Vercel
  # installation, so a valid signature does not prove the token was issued for
  # this tenant. Vercel sets `sub` to the Supabase project ref, so bind it here.
  defp check_vercel_subject(%{"iss" => @vercel_oidc_issuer_prefix <> _, "sub" => sub} = claims, tenant_external_id)
       when is_binary(tenant_external_id) and sub == tenant_external_id,
       do: {:ok, claims}

  defp check_vercel_subject(%{"iss" => @vercel_oidc_issuer_prefix <> _} = claims, _tenant_external_id),
    do: {:error, [message: "Invalid token", claim: "sub", claim_val: claims["sub"]]}

  defp check_vercel_subject(claims, _tenant_external_id), do: {:ok, claims}

  defp clean_token(token), do: Regex.replace(~r/\s|\n/, URI.decode(token), "")
end
