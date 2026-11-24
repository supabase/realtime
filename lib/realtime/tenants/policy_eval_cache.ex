defmodule Realtime.Tenants.PolicyEvalCache do
  @moduledoc """
  Caches a tenant's `PolicyEval.Snapshot`, loaded by `Realtime.Tenants.PolicyEvalLoader`, so it's built
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

  Besides the TTL, `reload/3` replaces an entry early, at most once per entry: shadow mode calls it on a
  mismatch, to tell a snapshot that went stale within the TTL from a real mismatch.
  """
  require Cachex.Spec

  alias PolicyEval.Snapshot
  alias Realtime.Tenants.PolicyEvalLoader

  defmodule Entry do
    @moduledoc """
    A cached snapshot and what the cache knows about it:

      * `loaded_at`: `System.monotonic_time(:millisecond)` when it was loaded, for its age
      * `load_reason`: `:ttl` when `fetch/2` loaded it on a miss, `:mismatch` when `reload/3` did.
        `reload/3` only replaces a `:ttl` entry, which is what bounds the extra loads
      * `id`: tells two entries apart, so callers that decided with the same entry share one reload
    """
    @enforce_keys [:snapshot, :loaded_at, :load_reason, :id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            snapshot: Snapshot.t(),
            loaded_at: integer(),
            load_reason: :ttl | :mismatch,
            id: reference()
          }

    @spec new(Snapshot.t(), :ttl | :mismatch) :: t()
    def new(snapshot, load_reason),
      do: %__MODULE__{snapshot: snapshot, loaded_at: now(), load_reason: load_reason, id: make_ref()}

    @doc "How long ago the entry was loaded, in milliseconds."
    @spec age_ms(t()) :: non_neg_integer()
    def age_ms(%__MODULE__{loaded_at: loaded_at}), do: now() - loaded_at

    defp now, do: System.monotonic_time(:millisecond)
  end

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: expiration())]]}
    }
  end

  @doc """
  Returns the tenant's cached entry, loading it through `PolicyEvalLoader.load/2` on a miss.

  `db_conn` is whatever connection the caller already has for the tenant; this module has no opinion
  on how it was obtained. A load failure isn't cached, so a transient database error doesn't make
  every join for that tenant fall back for a full TTL. `{:error, _}` can also come from Cachex itself
  (cache not running, the fallback crashing), not just a bad load — handled the same way either way.
  """
  @spec fetch(DBConnection.conn(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def fetch(db_conn, tenant_id) do
    __MODULE__
    |> Cachex.fetch(tenant_id, fn _key -> load(db_conn, tenant_id, :ttl) end)
    |> fetch_result()
  end

  @doc """
  Loads the tenant's snapshot again after a mismatch, caches it as a `:mismatch` entry and returns it.

  `decided_with` is the entry the mismatching decision came from, and must be a `:ttl` one. Callers
  that pass the same `decided_with` share one load, also after it finished: a reconnect after a
  policy change mismatches on many joins at once, and all of them get the same new entry to decide
  again with. The new entry has a full TTL and is never reloaded, so a tenant costs at most one extra
  load per `:ttl` entry, roughly one per TTL, however many of its decisions mismatch.

  A failed load replaces nothing and isn't cached, the same as in `fetch/2`.
  """
  @spec reload(DBConnection.conn(), String.t(), Entry.t()) :: {:ok, Entry.t()} | {:error, term()}
  def reload(db_conn, tenant_id, %Entry{load_reason: :ttl} = decided_with) do
    # Keyed by the entry the callers decided with. Cachex.fetch/3 runs the fallback once per key and
    # makes concurrent calls for that key wait for its result, so they all share one load; latecomers
    # get the cached result for the TTL instead of loading again.
    __MODULE__
    |> Cachex.fetch({:reload, tenant_id, decided_with.id}, fn _key ->
      with {:commit, entry} <- load(db_conn, tenant_id, :mismatch) do
        Cachex.put(__MODULE__, tenant_id, entry)
        {:commit, entry}
      end
    end)
    |> fetch_result()
  end

  @doc "Evicts a tenant's cached snapshot on this node, forcing the next `fetch/2` to reload."
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    Cachex.del(__MODULE__, tenant_id)
    :ok
  end

  defp load(db_conn, tenant_id, load_reason) do
    case PolicyEvalLoader.load(db_conn, tenant_id) do
      {:ok, snapshot} -> {:commit, Entry.new(snapshot, load_reason)}
      {:error, _} = error -> {:ignore, error}
    end
  end

  defp fetch_result({:commit, value}), do: {:ok, value}
  defp fetch_result({:ok, value}), do: {:ok, value}
  defp fetch_result({:ignore, error}), do: error
  defp fetch_result({:error, _} = error), do: error

  defp expiration, do: Application.fetch_env!(:realtime, :policy_eval_snapshot_cache_expiration)
end
