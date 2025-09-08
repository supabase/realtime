defmodule Realtime.Api do
  @moduledoc """
  The Api context.
  """
  require Logger

  import Ecto.Query

  alias Realtime.Api.Extensions
  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Repo
  alias Realtime.Repo.Replica
  alias Realtime.Tenants
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.SocketDisconnect

  defguard requires_disconnect(changeset)
           when changeset.valid? == true and
                  (is_map_key(changeset.changes, :jwt_secret) or
                     is_map_key(changeset.changes, :jwt_jwks) or
                     is_map_key(changeset.changes, :private_only) or
                     is_map_key(changeset.changes, :suspend))

  defguard requires_restarting_db_connection(changeset)
           when changeset.valid? == true and
                  (is_map_key(changeset.changes, :extensions) or
                     is_map_key(changeset.changes, :jwt_secret) or
                     is_map_key(changeset.changes, :jwt_jwks) or
                     is_map_key(changeset.changes, :suspend))

  @doc """
  Returns the list of tenants.

  ## Examples

      iex> list_tenants()
      [%Tenant{}, ...]

  """
  def list_tenants do
    repo_replica = Replica.replica()

    Tenant
    |> repo_replica.all()
    |> repo_replica.preload(:extensions)
  end

  @doc """
  Returns list of tenants with filter options:
  * order_by
  * search external id
  * limit
  * ordering (desc / asc)
  """
  def list_tenants(opts) when is_list(opts) do
    repo_replica = Replica.replica()

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
  def get_tenant!(id), do: Replica.replica().get!(Tenant, id)

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
    changeset = Tenant.changeset(tenant, attrs)
    updated = Repo.update(changeset)

    case updated do
      {:ok, tenant} ->
        maybe_invalidate_cache(changeset)
        maybe_trigger_disconnect(changeset)
        maybe_restart_db_connection(changeset)
        Logger.debug("Tenant updated: #{inspect(tenant, pretty: true)}")

      {:error, error} ->
        Logger.error("Failed to update tenant: #{inspect(error, pretty: true)}")
    end

    updated
  end

  @doc """
  Deletes a tenant.

  ## Examples

      iex> delete_tenant(tenant)
      {:ok, %Tenant{}}

      iex> delete_tenant(tenant)
      {:error, %Ecto.Changeset{}}

  """
  def delete_tenant(%Tenant{} = tenant), do: Repo.delete(tenant)

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

  @spec get_tenant_by_external_id(String.t(), atom()) :: Tenant.t() | nil
  def get_tenant_by_external_id(external_id, repo \\ :replica)
      when repo in [:primary, :replica] do
    repo =
      case repo do
        :primary -> Repo
        :replica -> Replica.replica()
      end

    Tenant
    |> repo.get_by(external_id: external_id)
    |> repo.preload(:extensions)
  end

  defp list_extensions(type) do
    query = from(e in Extensions, where: e.type == ^type, select: e)

    Repo.all(query)
  end

  def rename_settings_field(from, to) do
    for extension <- list_extensions("postgres_cdc_rls") do
      {value, settings} = Map.pop(extension.settings, from)
      new_settings = Map.put(settings, to, value)

      extension
      |> Ecto.Changeset.cast(%{settings: new_settings}, [:settings])
      |> Repo.update!()
    end
  end

  def preload_counters(nil), do: nil

  def preload_counters(%Tenant{} = tenant) do
    rate = Tenants.requests_per_second_rate(tenant)

    preload_counters(tenant, rate)
  end

  def preload_counters(nil, _rate), do: nil

  def preload_counters(%Tenant{} = tenant, counters_rate) do
    current = GenCounter.get(counters_rate.id)
    {:ok, %RateCounter{avg: avg}} = RateCounter.get(counters_rate)

    tenant
    |> Map.put(:events_per_second_rolling, avg)
    |> Map.put(:events_per_second_now, current)
  end

  defp maybe_invalidate_cache(
         %Ecto.Changeset{changes: changes, valid?: true, data: %{external_id: external_id}} = changeset
       )
       when changes != %{} and requires_restarting_db_connection(changeset) do
    Tenants.Cache.distributed_invalidate_tenant_cache(external_id)
  end

  defp maybe_invalidate_cache(_changeset), do: nil

  defp maybe_trigger_disconnect(%Ecto.Changeset{data: %{external_id: external_id}} = changeset)
       when requires_disconnect(changeset) do
    SocketDisconnect.distributed_disconnect(external_id)
  end

  defp maybe_trigger_disconnect(_changeset), do: nil

  defp maybe_restart_db_connection(%Ecto.Changeset{data: %{external_id: external_id}} = changeset)
       when requires_restarting_db_connection(changeset) do
    Connect.shutdown(external_id)
  end

  defp maybe_restart_db_connection(_changeset), do: nil
end
