defmodule Realtime.ApiJwt.Validator do
  @moduledoc """
  Configuration for validating a JWT to manage tenants.

  Each validator describes one accepted JWT "type" and is matched against an
  incoming token by its `iss` claim. Multiple validators can be configured at
  once (via the `API_JWT_VALIDATORS` env var) to support issuer/key rotation.

  The signature is always verified against an asymmetric key from the JWKS
  fetched at `jwks_url`. The token's own `alg` is honoured as long as it is one
  we support (RS*/ES*/Ed*); symmetric (HS*) and `none` are structurally
  rejected during signer generation, so there is no per-validator algorithm
  allowlist to configure.
  """

  @enforce_keys [:jwks_url, :issuer, :audiences, :subjects]
  defstruct [:jwks_url, :issuer, :audiences, :subjects]

  @type t :: %__MODULE__{
          jwks_url: binary(),
          issuer: binary(),
          audiences: [binary()],
          subjects: [binary()]
        }

  @doc """
  Parses the `API_JWT_VALIDATORS` JSON string into a list of validators.

  Expects a JSON array of objects. Returns `{:error, reason}` when the JSON is
  malformed or any entry is invalid.
  """
  @spec parse(binary()) :: {:ok, [t()]} | {:error, term()}
  def parse(json) when is_binary(json) do
    with {:ok, decoded} <- Jason.decode(json),
         :ok <- validate_list(decoded) do
      reduce_entries(decoded)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, _} = error -> error
    end
  end

  defp validate_list(list) when is_list(list), do: :ok
  defp validate_list(_), do: {:error, :not_a_list}

  defp reduce_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case from_map(entry) do
        {:ok, validator} -> {:cont, {:ok, [validator | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validators} -> {:ok, Enum.reverse(validators)}
      error -> error
    end
  end

  defp from_map(%{"jwks_url" => jwks_url, "issuer" => issuer, "audience" => audience, "subject" => subject})
       when is_binary(jwks_url) and is_binary(issuer) do
    with {:ok, audiences} <- to_string_list(audience, :audience),
         {:ok, subjects} <- to_string_list(subject, :subject) do
      {:ok,
       %__MODULE__{
         jwks_url: jwks_url,
         issuer: issuer,
         audiences: audiences,
         subjects: subjects
       }}
    end
  end

  defp from_map(_), do: {:error, :missing_required_fields}

  defp to_string_list(value, _field) when is_binary(value), do: {:ok, [value]}

  defp to_string_list(value, field) when is_list(value) do
    cond do
      value == [] -> {:error, {:empty, field}}
      Enum.all?(value, &is_binary/1) -> {:ok, value}
      true -> {:error, {:invalid, field}}
    end
  end

  defp to_string_list(_value, field), do: {:error, {:invalid, field}}
end
