defmodule RealtimeWeb.JwtVerification do
  @moduledoc """
  Parse JWT and verify claims
  """
  # Matching error in Dialyzer when using Joken.peek_claims/1 but {:ok, []} is actually possible and covered by our testing
  @dialyzer {:nowarn_function, check_claims_format: 1}

  defmodule JwtAuthToken do
    @moduledoc false
    use Joken.Config

    @impl true
    def token_config do
      Application.fetch_env!(:realtime, :jwt_claim_validators)
      |> Enum.reduce(%{}, fn {claim_key, expected_val}, claims ->
        add_claim_validator(claims, claim_key, expected_val)
      end)
      |> add_claim_validator("exp")
    end

    defp add_claim_validator(claims, "exp") do
      current_time = current_time()
      add_claim(claims, "exp", nil, &(&1 > current_time), message: current_time)
    end

    defp add_claim_validator(claims, claim_key, expected_val) do
      add_claim(claims, claim_key, nil, &(&1 == expected_val))
    end
  end

  @hs_algorithms ["HS256", "HS384", "HS512"]
  @rs_algorithms ["RS256", "RS384", "RS512"]
  @es_algorithms ["ES256", "ES384", "ES512"]
  @ed_algorithms ["Ed25519", "Ed448"]

  @doc """
  Verify JWT token and validate claims
  """
  @spec verify(binary(), binary(), map() | nil) :: {:ok, map()} | {:error, any()}
  def verify(token, jwt_secret, jwt_jwks) when is_binary(token) do
    with {:ok, claims} <- check_claims_format(token),
         {:ok, header} <- check_header_format(token),
         {:ok, jwt_jwks} <- maybe_fetch_jwks(claims, header, jwt_jwks),
         {:ok, signer} <- generate_signer(header, jwt_secret, jwt_jwks) do
      JwtAuthToken.verify_and_validate(token, signer)
    else
      {:error, _e} = error -> error
    end
  end

  def verify(_token, _jwt_secret, _jwt_jwks), do: {:error, :not_a_string}

  defp check_claims_format(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, _} -> {:error, :expected_claims_map}
      {:error, :token_malformed} -> {:error, :token_malformed}
    end
  end

  defp check_header_format(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _error -> {:error, :expected_header_map}
    end
  end

  defp maybe_fetch_jwks(_claims, _header, %{"keys" => keys} = jwks) when is_list(keys), do: {:ok, jwks}
  defp maybe_fetch_jwks(_claims, _header, %{keys: keys} = jwks) when is_list(keys), do: {:ok, normalize_jwks(jwks)}

  defp maybe_fetch_jwks(claims, %{"kid" => kid}, jwt_jwks) when is_binary(kid) do
    issuer = issuer_from(claims, jwt_jwks)

    case issuer do
      nil -> {:ok, jwt_jwks}
      issuer ->
        case fetch_jwks_from_issuer(issuer) do
          {:ok, fetched_jwks} -> {:ok, fetched_jwks}
          _ -> {:ok, jwt_jwks}
        end
    end
  end

  defp maybe_fetch_jwks(_claims, _header, jwt_jwks), do: {:ok, jwt_jwks}

  defp issuer_from(_claims, %{"issuer" => issuer}) when is_binary(issuer), do: trim_issuer(issuer)
  defp issuer_from(_claims, %{issuer: issuer}) when is_binary(issuer), do: trim_issuer(issuer)
  defp issuer_from(%{"iss" => issuer}, _jwt_jwks) when is_binary(issuer), do: trim_issuer(issuer)
  defp issuer_from(_claims, _jwt_jwks), do: nil

  defp trim_issuer(issuer), do: issuer |> String.trim() |> String.trim_trailing("/")

  defp fetch_jwks_from_issuer(issuer) do
    discovery_url = "#{issuer}/.well-known/openid-configuration"
    fallback_jwks_url = "#{issuer}/.well-known/jwks.json"

    with {:ok, discovery} <- fetch_json(discovery_url),
         {:ok, jwks_uri} <- extract_jwks_uri(discovery, issuer),
         {:ok, jwks} <- fetch_json(jwks_uri),
         {:ok, jwks} <- normalize_and_validate_jwks(jwks) do
      {:ok, jwks}
    else
      _ ->
        with {:ok, jwks} <- fetch_json(fallback_jwks_url),
             {:ok, jwks} <- normalize_and_validate_jwks(jwks) do
          {:ok, jwks}
        end
    end
  end

  defp fetch_json(url) do
    case Req.get(url: url) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      _ ->
        {:error, :failed_to_fetch_jwks}
    end
  end

  defp extract_jwks_uri(%{"jwks_uri" => jwks_uri}, issuer) when is_binary(jwks_uri) do
    {:ok, resolve_jwks_uri(issuer, jwks_uri)}
  end

  defp extract_jwks_uri(%{jwks_uri: jwks_uri}, issuer) when is_binary(jwks_uri) do
    {:ok, resolve_jwks_uri(issuer, jwks_uri)}
  end

  defp extract_jwks_uri(_discovery, _issuer), do: {:error, :missing_jwks_uri}

  defp resolve_jwks_uri(issuer, jwks_uri) do
    uri = URI.parse(jwks_uri)

    if uri.scheme do
      jwks_uri
    else
      URI.merge("#{issuer}/", jwks_uri) |> to_string()
    end
  end

  defp normalize_and_validate_jwks(%{"keys" => keys} = jwks) when is_list(keys), do: {:ok, jwks}
  defp normalize_and_validate_jwks(%{keys: keys} = jwks) when is_list(keys), do: {:ok, normalize_jwks(jwks)}
  defp normalize_and_validate_jwks(_jwks), do: {:error, :invalid_jwks}

  defp normalize_jwks(%{keys: keys}), do: %{"keys" => keys}
  defp normalize_jwks(jwks), do: jwks

  defp generate_signer(%{"alg" => alg, "kid" => kid}, _jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @rs_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "RSA" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  defp generate_signer(%{"alg" => alg, "kid" => kid}, _jwt_secret, %{"keys" => keys})
       when is_binary(kid) and alg in @es_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "EC" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  defp generate_signer(%{"alg" => alg, "kid" => kid}, _jwt_secret, %{"keys" => keys})
       when is_binary(kid) and alg in @ed_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "OKP" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  # Most Supabase Auth JWTs fall in this case, as they're usually signed with
  # HS256, have a kid header, but there's no JWK as this is sensitive. In this
  # case, the jwt_secret should be used.
  defp generate_signer(%{"alg" => alg, "kid" => kid}, jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @hs_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "oct" and jwk["kid"] == kid and is_binary(jwk["k"]) end)

    if jwk do
      case Base.url_decode64(jwk["k"], padding: false) do
        {:ok, secret} -> {:ok, Joken.Signer.create(alg, secret)}
        _ -> {:error, :error_generating_signer}
      end
    else
      # If there's no JWK, and HS* is being used, instead of erroring, try
      # the jwt_secret instead.
      {:ok, Joken.Signer.create(alg, jwt_secret)}
    end
  end

  defp generate_signer(%{"alg" => alg}, jwt_secret, _jwt_jwks) when alg in @hs_algorithms do
    {:ok, Joken.Signer.create(alg, jwt_secret)}
  end

  defp generate_signer(_header, _jwt_secret, _jwt_jwks), do: {:error, :error_generating_signer}
end
