defmodule Realtime.FeatureFlags.Cache do
  @moduledoc """
  In-process Cachex cache for `Realtime.Api.FeatureFlag` records.

  Cache misses fall through to the database automatically via `Cachex.fetch/3`.
  Nil results (flag not found) are intentionally not cached so that newly
  created flags become visible without requiring an explicit invalidation.

  Use `global_update_cache/1` after mutations to push the updated struct to all
  cluster nodes. Use `global_invalidate_cache/1` after deletes.
  """

  require Cachex.Spec
  alias Realtime.Api
  alias Realtime.Api.FeatureFlag
  alias Realtime.GenRpc

  def child_spec(_) do
    tenant_cache_expiration = Application.get_env(:realtime, :tenant_cache_expiration)

    %{
      id: __MODULE__,
      start: {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: tenant_cache_expiration)]]}
    }
  end

  @spec get_flag(String.t()) :: FeatureFlag.t() | nil
  def get_flag(name) do
    with {_, value} <-
           Cachex.fetch(__MODULE__, cache_key(name), fn _key ->
             with %FeatureFlag{} = flag <- Api.get_feature_flag(name),
                  do: {:commit, flag},
                  else: (_ -> {:ignore, nil})
           end) do
      value
    end
  end

  @spec update_cache(FeatureFlag.t()) :: {:ok, boolean()} | {:error, boolean()}
  def update_cache(%FeatureFlag{} = flag) do
    Cachex.put(__MODULE__, cache_key(flag.name), flag)
  end

  @spec invalidate_cache(String.t()) :: {:ok, boolean()} | {:error, boolean()}
  def invalidate_cache(name) when is_binary(name) do
    Cachex.del(__MODULE__, cache_key(name))
  end

  @spec global_update_cache(FeatureFlag.t()) :: :ok
  def global_update_cache(%FeatureFlag{} = flag) do
    GenRpc.multicast(__MODULE__, :update_cache, [flag])
  end

  @spec global_invalidate_cache(FeatureFlag.t()) :: :ok
  def global_invalidate_cache(%FeatureFlag{} = flag) do
    GenRpc.multicast(__MODULE__, :invalidate_cache, [flag.name])
  end

  defp cache_key(name), do: {:get_flag, name}
end
