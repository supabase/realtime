defmodule Realtime.Api do
  @moduledoc """
  The Api context.
  """
  require Logger

  import Ecto.Query, warn: false, only: [from: 2]

  alias Realtime.{Repo, Api.Tenant, Api.Extensions, RateCounter, GenCounter}

  @doc """
  Returns the list of tenants.

  ## Examples

      iex> list_tenants()
      [%Tenant{}, ...]

  """
  def list_tenants do
    repo_replica = Repo.replica()

    Tenant
    |> repo_replica.all()
    |> repo_replica.preload(:extensions)
  end

  @doc """
  Gets a single tenant.

  Raises `Ecto.NoResultsError` if the Tenant does not exist.

  ## Examples

      iex> _by_host!(123) do

      end

      %Tenant{}

      iex> get_tenant!(456)
      ** (Ecto.NoResultsError)

  """
  def get_tenant!(id), do: Repo.replica().get!(Tenant, id)

  @doc """
  Creates a tenant.

  ## Examples

      iex> create_tenant(%{field: value})
      {:ok, %Tenant{}}

      iex> create_tenant(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_tenant(attrs) do
    Logger.debug("create_tenant #{inspect(attrs, pretty: true)}")

    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a tenant.

  ## Examples

      iex> update_tenant(tenant, %{field: new_value})
      {:ok, %Tenant{}}

      iex> update_tenant(tenant, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_tenant(%Tenant{} = tenant, attrs) do
    drop_dist_cache(tenant.external_id)

    tenant
    |> Tenant.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a tenant.

  ## Examples

      iex> delete_tenant(tenant)
      {:ok, %Tenant{}}

      iex> delete_tenant(tenant)
      {:error, %Ecto.Changeset{}}

  """
  def delete_tenant(%Tenant{} = tenant) do
    Repo.delete(tenant)
  end

  @spec delete_tenant_by_external_id(String.t()) :: boolean()
  def delete_tenant_by_external_id(id) do
    drop_dist_cache(id)

    from(t in Tenant, where: t.external_id == ^id)
    |> Repo.delete_all()
    |> case do
      {num, _} when num > 0 ->
        true

      _ ->
        false
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking tenant changes.

  ## Examples

      iex> change_tenant(tenant)
      %Ecto.Changeset{data: %Tenant{}}

  """
  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end

  @spec get_tenant_by_external_id(String.t()) :: Tenant.t() | nil
  def get_tenant_by_external_id(external_id) do
    repo_replica = Repo.replica()

    Tenant
    |> repo_replica.get_by(external_id: external_id)
    |> repo_replica.preload(:extensions)
  end

  def get_cached_tenant(external_id) do
    {status, value} =
      Cachex.fetch(:db_cache, external_id, fn ->
        get_tenant_by_external_id(external_id)
      end)

    if status == :commit, do: Cachex.expire(:db_cache, external_id, 60_000)
    value
  end

  def list_extensions(type \\ "postgres_cdc_rls") do
    from(e in Extensions,
      where: e.type == ^type,
      select: e
    )
    |> Repo.replica().all()
  end

  def rename_settings_field(from, to) do
    for extension <- list_extensions("postgres_cdc_rls") do
      {value, settings} = Map.pop(extension.settings, from)
      new_settings = Map.put(settings, to, value)

      Ecto.Changeset.cast(extension, %{settings: new_settings}, [:settings])
      |> Repo.update!()
    end
  end

  def preload_counters(nil) do
    nil
  end

  def preload_counters(%Tenant{} = tenant) do
    id = {:limit, :all, tenant.external_id}

    preload_counters(tenant, id)
  end

  def preload_counters(nil, _key) do
    nil
  end

  def preload_counters(%Tenant{} = tenant, counters_key) do
    {:ok, current} = GenCounter.get(counters_key)
    {:ok, %RateCounter{avg: avg}} = RateCounter.get(counters_key)

    tenant
    |> Map.put(:events_per_second_rolling, avg)
    |> Map.put(:events_per_second_now, current)
  end

  def get_tenant_limits(%Tenant{} = tenant) do
    limiter_keys = [
      {:limit, :all, tenant.external_id},
      {:limit, :user_channels, tenant.external_id},
      {:limit, :channel_joins, tenant.external_id},
      {:limit, :tenant_events, tenant.external_id}
    ]

    nodes = [Node.self() | Node.list()]

    nodes
    |> Enum.map(fn node ->
      Task.Supervisor.async({Realtime.TaskSupervisor, node}, fn ->
        for {_key, name, _external_id} = key <- limiter_keys do
          {_status, response} = Realtime.GenCounter.get(key)

          %{
            external_id: tenant.external_id,
            node: node,
            limiter: name,
            counter: response
          }
        end
      end)
    end)
    |> Task.await_many()
    |> List.flatten()
  end

  def drop_dist_cache(id) do
    {_, bad_nodes} =
      [node() | Node.list()]
      |> :rpc.multicall(Cachex, :del, [:db_cache, id], 10_000)

    if bad_nodes != [], do: Logger.error("Failed to drop cache on nodes: #{inspect(bad_nodes)}")
  end
end
