defmodule RealtimeWeb.ApiJwtVerification do
  @moduledoc """
  Verifies platform-issued JWTs used to authenticate against the
  management API.

  These are asymmetric, OIDC-style JWTs signed by the platform's identity
  provider. A token is matched to a configured
  `Realtime.ApiJwt.Validator` by its `iss` claim, its signature is verified
  against a JWKS fetched from the validator's `jwks_url`, and its `iss`/`aud`/
  `sub`/`exp` claims are validated. Multiple validators can be configured for
  issuer/key rotation.
  """

  alias Realtime.ApiJwt.Jwks
  alias RealtimeWeb.JwtVerification

  @doc """
  Verifies an API JWT against the configured validators.

  Returns `{:ok, claims}` on the first validator that matches and verifies,
  otherwise an error.
  """
  @spec verify(binary()) :: {:ok, map()} | {:error, term()}
  def verify(token) when is_binary(token) do
    validators = Application.get_env(:realtime, :api_jwt_validators, [])

    with {:ok, claims} <- peek_claims(token),
         {:ok, header} <- peek_header(token),
         {:ok, matching} <- matching_validators(validators, claims) do
      verify_with_any(token, header, matching)
    end
  end

  def verify(_token), do: {:error, :not_a_string}

  defp peek_claims(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> {:error, :token_malformed}
    end
  end

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :expected_header_map}
    end
  end

  defp matching_validators(validators, %{"iss" => iss}) when is_binary(iss) do
    case Enum.filter(validators, &(&1.issuer == iss)) do
      [] -> {:error, :no_matching_validator}
      matching -> {:ok, matching}
    end
  end

  defp matching_validators(_validators, _claims), do: {:error, :missing_iss}

  defp verify_with_any(token, header, validators) do
    Enum.reduce_while(validators, {:error, :no_matching_validator}, fn validator, _acc ->
      case verify_with_validator(token, header, validator) do
        {:ok, claims} -> {:halt, {:ok, claims}}
        {:error, _} = error -> {:cont, error}
      end
    end)
  end

  # The token's own alg is honoured as long as it is one we support. Only
  # asymmetric algorithms are accepted: symmetric (HS*) and `none` never reach
  # signer generation, so a public key can't be abused as an HMAC secret. This
  # cheap guard also avoids a JWKS fetch/refresh for unsupported algs.
  @supported_algorithms ~w(RS256 RS384 RS512 ES256 ES384 ES512 Ed25519 Ed448)

  defp verify_with_validator(token, %{"alg" => alg} = header, validator) do
    if alg in @supported_algorithms do
      with {:ok, signer} <- signer_for(header, validator) do
        Joken.verify_and_validate(claim_config(validator), token, signer)
      end
    else
      {:error, :alg_not_allowed}
    end
  end

  defp verify_with_validator(_token, _header, _validator), do: {:error, :error_generating_signer}

  # Try the cached JWKS first; on an unknown kid the key may have been rotated in,
  # so refresh the JWKS and retry once.
  defp signer_for(header, validator) do
    with {:ok, jwks} <- Jwks.fetch(validator.jwks_url),
         {:error, :error_generating_signer} <- JwtVerification.asymmetric_signer_from_jwks(header, jwks),
         {:ok, jwks} <- Jwks.refresh(validator.jwks_url) do
      JwtVerification.asymmetric_signer_from_jwks(header, jwks)
    end
  end

  defp claim_config(validator) do
    current_time = Joken.current_time()

    %{}
    |> Joken.Config.add_claim("exp", nil, &(is_number(&1) and &1 > current_time))
    |> Joken.Config.add_claim("iss", nil, &(&1 == validator.issuer))
    |> Joken.Config.add_claim("aud", nil, &aud_valid?(&1, validator.audiences))
    |> Joken.Config.add_claim("sub", nil, &(&1 in validator.subjects))
  end

  defp aud_valid?(aud, audiences) when is_binary(aud), do: aud in audiences
  defp aud_valid?(aud, audiences) when is_list(aud), do: Enum.any?(aud, &(&1 in audiences))
  defp aud_valid?(_aud, _audiences), do: false
end
