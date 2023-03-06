defmodule Realtime.Api do
  @moduledoc """
  The Api context.
  """
  require Logger

  import Ecto.Query

  alias Realtime.{Repo, Api.Tenant, Api.Extensions, RateCounter, GenCounter, Tenants}

  @doc """
  Returns the list of tenants.

  ## Examples

      iex> list_tenants()
      [%Tenant{}, ...]

  """
  def list_tenants() do
    repo_replica = Repo.replica()

    Tenant
    |> repo_replica.all()
    |> repo_replica.preload(:extensions)
  end

  def list_tenants(opts) when is_list(opts) do
    repo_replica = Repo.replica()

    field = Keyword.get(opts, :order_by, "inserted_at") |> String.to_atom()
    external_id = Keyword.get(opts, :search)
    limit = Keyword.get(opts, :limit, 50)
    order = Keyword.get(opts, :order, "desc") |> String.to_atom()

    query =
      Tenant
      |> order_by({^order, ^field})
      |> limit(^limit)

    ilike = "#{external_id}%"

    query = if external_id, do: query |> where([t], ilike(t.external_id, ^ilike)), else: query

    query
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
    id = Tenants.requests_per_second_key(tenant)

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
end
