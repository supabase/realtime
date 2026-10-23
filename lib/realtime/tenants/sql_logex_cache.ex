defmodule Realtime.Tenants.SqlLogexCache do
  @moduledoc """
  Caches a tenant's `SqlLogex.Snapshot`, loaded by `Realtime.Tenants.SqlLogexLoader`, so it's built
  once per TTL rather than once per join.

  One cache per node, no cross-node propagation: `get_read_authorizations/4` and
  `get_write_authorizations/4` (`Realtime.Tenants.Authorization`) either run locally or dispatch the
  entire call via `GenRpc` to the node holding the tenant's `db_conn`, so by the time anything calls
  `fetch/2` it's already running on the one node that owns that connection. There's no second node
  that would ever need this tenant's entry while nothing decides before that dispatch (an enforce-mode
  concern, not here).

  A plain TTL: the first `fetch/2` after an entry expires pays the full reload synchronously, the same
  as `Realtime.Tenants.Cache` and `Realtime.FeatureFlags.Cache`. A refresh-ahead cache (check and
  update entries before they expire, so readers never block on a cold one) would be better, but that's
  a job for whatever periodic per-tenant process ends up owning it, not this module.
  """
  require Cachex.Spec

  alias Realtime.Tenants.SqlLogexLoader
  alias SqlLogex.Snapshot

  def child_spec(_) do
    expiration = Application.fetch_env!(:realtime, :sql_logex_snapshot_cache_expiration)

    %{
      id: __MODULE__,
      start: {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: expiration)]]}
    }
  end

  @doc """
  Returns the tenant's cached snapshot, loading it through `SqlLogexLoader.load/2` on a miss.

  `db_conn` is whatever connection the caller already has for the tenant; this module has no opinion
  on how it was obtained. A load failure isn't cached, so a transient database error doesn't make
  every join for that tenant fall back for a full TTL. `{:error, _}` can also come from Cachex itself
  (cache not running, the fallback crashing), not just a bad load — handled the same way either way.
  """
  @spec fetch(DBConnection.conn(), String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def fetch(db_conn, tenant_id) do
    case Cachex.fetch(__MODULE__, tenant_id, fn _key ->
           case SqlLogexLoader.load(db_conn, tenant_id) do
             {:ok, snapshot} -> {:commit, snapshot}
             {:error, _} = error -> {:ignore, error}
           end
         end) do
      {:commit, value} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      {:ignore, error} -> error
      {:error, _} = error -> error
    end
  end

  @doc "Evicts a tenant's cached snapshot on this node, forcing the next `fetch/2` to reload."
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    Cachex.del(__MODULE__, tenant_id)
    :ok
  end
end
