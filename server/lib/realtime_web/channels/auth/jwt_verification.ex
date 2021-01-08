defmodule RealtimeWeb.JwtVerification do
  defmodule JwtAuthToken do
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
      add_claim(claims, "exp", nil, &(&1 > current_time()))
    end

    defp add_claim_validator(claims, claim_key, expected_val) do
      add_claim(claims, claim_key, nil, &(&1 == expected_val))
    end
  end

  @hs_algorithms ["HS256", "HS384", "HS512"]

  def verify(token) when is_binary(token) do
    with :ok <- check_claims_format(token),
         {:ok, header} <- check_header_format(token),
         {:ok, signer} <- generate_signer(header) do
      JwtAuthToken.verify_and_validate(token, signer)
    else
      _ -> :error
    end
  end

  def verify(_token), do: :error

  defp check_header_format(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> :error
    end
  end

  defp check_claims_format(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} when is_map(claims) -> :ok
      _ -> :error
    end
  end

  defp generate_signer(%{"typ" => "JWT", "alg" => alg}) when alg in @hs_algorithms do
    {:ok,
     Joken.Signer.create(
       alg,
       Application.fetch_env!(:realtime, :jwt_secret)
     )}
  end

  defp generate_signer(_header), do: :error
end
