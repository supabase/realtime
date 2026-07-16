defmodule Realtime.ApiJwt.Jwks do
  @moduledoc """
  Fetches and caches JSON Web Key Sets (JWKS) used to verify the platform-issued
  JWTs presented to the management API.

  A JWKS is fetched over HTTP from the validator's `jwks_url` and cached with a
  TTL. Cachex's courier de-duplicates concurrent fetches for the same URL so a
  burst of requests results in a single HTTP call. On an unknown `kid` the
  caller can `refresh/1` to re-fetch (handles key rotation), which is rate
  limited so unrecognized `kid`s cannot force unbounded re-fetches.
  """

  require Logger

  @cache __MODULE__
  @ttl_ms :timer.minutes(10)
  @refresh_cooldown_ms :timer.minutes(1)
  @receive_timeout_ms :timer.seconds(5)

  @doc "Returns the cached JWKS for `jwks_url`, fetching and caching it on a miss."
  @spec fetch(binary()) :: {:ok, map()} | {:error, term()}
  def fetch(jwks_url) when is_binary(jwks_url) do
    @cache
    |> Cachex.fetch(jwks_url, fn url ->
      case get(url) do
        {:ok, jwks} -> {:commit, jwks, expire: @ttl_ms}
        {:error, _} = error -> {:ignore, error}
      end
    end)
    |> case do
      {:ok, jwks} -> {:ok, jwks}
      {:commit, jwks} -> {:ok, jwks}
      {:ignore, {:error, _} = error} -> error
      {:error, _} = error -> error
    end
  end

  @doc """
  Re-fetches the JWKS for `jwks_url` after an unknown `kid`, at most once per
  cooldown window per URL.

  Without a cooldown, a flood of tokens carrying `kid`s we don't recognize (the
  `iss` and `alg` needed to reach this path are not secret) would force a JWKS
  re-fetch on every request. The cooldown key's TTL bounds sequential re-fetches
  while Cachex's courier de-duplicates concurrent ones, so an unknown-`kid` storm
  triggers at most one HTTP call per window. On a successful re-fetch the main
  cache entry is refreshed too, so a genuinely rotated-in key is picked up; on a
  failed re-fetch the previously cached JWKS is left intact.
  """
  @spec refresh(binary()) :: {:ok, map()} | {:error, term()}
  def refresh(jwks_url) when is_binary(jwks_url) do
    @cache
    |> Cachex.fetch({:refresh, jwks_url}, fn {:refresh, url} ->
      case get(url) do
        {:ok, jwks} = ok ->
          Cachex.put(@cache, url, jwks, expire: @ttl_ms)
          {:commit, ok, expire: @refresh_cooldown_ms}

        {:error, _} = error ->
          {:commit, error, expire: @refresh_cooldown_ms}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:commit, result} -> result
      {:error, _} = error -> error
    end
  end

  defp get(url) do
    options =
      [url: url, method: :get, receive_timeout: @receive_timeout_ms]
      |> Keyword.merge(Application.get_env(:realtime, :api_jwt_jwks_req_options, []))

    case Req.request(options) do
      {:ok, %{status: status, body: %{"keys" => keys} = jwks}} when status in 200..299 and is_list(keys) ->
        {:ok, jwks}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.error("API JWT JWKS fetch returned an invalid JWKS from #{url}: #{inspect(body)}")
        {:error, :invalid_jwks}

      {:ok, %{status: status}} ->
        Logger.error("API JWT JWKS fetch failed for #{url} with status #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("API JWT JWKS fetch failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
