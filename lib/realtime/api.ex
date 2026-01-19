defmodule Realtime.Api do
  @moduledoc """
  The Api context.
  """
  require Logger

  import Ecto.Query

  alias Ecto.Changeset
  alias Realtime.Api.Extensions
  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.GenRpc
  alias Realtime.Nodes
  alias Realtime.RateCounter
  alias Realtime.Repo
  alias Realtime.Repo.Replica
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache
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
    tenant_id = Map.get(attrs, :external_id) || Map.get(attrs, "external_id")

    if master_region?() do
      %Tenant{}
      |> Tenant.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, tenant} ->
          Cache.global_cache_update(tenant)
          {:ok, tenant}

        error ->
          error
      end
    else
      call(:create_tenant, [attrs], tenant_id)
    end
  end

  @doc """
  Updates a tenant.
  """
  @spec update_tenant_by_external_id(binary(), map()) :: {:ok, Tenant.t()} | {:error, term()}
  def update_tenant_by_external_id(tenant_id, attrs) when is_binary(tenant_id) do
    if master_region?() do
      tenant_id
      |> get_tenant_by_external_id(use_replica?: false)
      |> update_tenant(attrs)
    else
      call(:update_tenant_by_external_id, [tenant_id, attrs], tenant_id)
    end
  end

  defp update_tenant(%Tenant{} = tenant, attrs) do
    changeset = Tenant.changeset(tenant, attrs)
    updated = Repo.update(changeset)

    case updated do
      {:ok, tenant} ->
        maybe_update_cache(tenant, changeset)
        maybe_trigger_disconnect(changeset)
        maybe_restart_db_connection(changeset)
        maybe_restart_rate_counters(changeset)
        Logger.debug("Tenant updated: #{inspect(tenant, pretty: true)}")

      {:error, error} ->
        Logger.error("Failed to update tenant: #{inspect(error, pretty: true)}")
    end

    updated
  end

  @spec delete_tenant_by_external_id(String.t()) :: boolean()
  def delete_tenant_by_external_id(id) do
    if master_region?() do
      query = from(t in Tenant, where: t.external_id == ^id)
      {num, _} = Repo.delete_all(query)
      num > 0
    else
      call(:delete_tenant_by_external_id, [id], id)
    end
  end

  @spec get_tenant_by_external_id(String.t(), Keyword.t()) :: Tenant.t() | nil
  def get_tenant_by_external_id(external_id, opts \\ []) do
    use_replica? = Keyword.get(opts, :use_replica?, true)

    cond do
      use_replica? ->
        Replica.replica().get_by(Tenant, external_id: external_id) |> Replica.replica().preload(:extensions)

      !use_replica? and master_region?() ->
        Repo.get_by(Tenant, external_id: external_id) |> Repo.preload(:extensions)

      true ->
        call(:get_tenant_by_external_id, [external_id, opts], external_id)
    end
  end

  defp list_extensions(type) do
    query = from(e in Extensions, where: e.type == ^type, select: e)
    replica = Replica.replica()
    replica.all(query)
  end

  def rename_settings_field(from, to) do
    if master_region?() do
      for extension <- list_extensions("postgres_cdc_rls") do
        {value, settings} = Map.pop(extension.settings, from)
        new_settings = Map.put(settings, to, value)

        extension
        |> Changeset.cast(%{settings: new_settings}, [:settings])
        |> Repo.update()
      end
    else
      call(:rename_settings_field, [from, to], from)
    end
  end

  @spec preload_counters(nil | Realtime.Api.Tenant.t(), any()) :: nil | Realtime.Api.Tenant.t()
  @doc """
  Updates the migrations_ran field for a tenant.
  """
  @spec update_migrations_ran(binary(), integer()) :: {:ok, Tenant.t()} | {:error, term()}
  def update_migrations_ran(external_id, count) do
    if master_region?() do
      tenant = get_tenant_by_external_id(external_id, use_replica?: false)

      tenant
      |> Tenant.changeset(%{migrations_ran: count})
      |> Repo.update()
      |> tap(fn result ->
        case result do
          {:ok, tenant} -> Cache.global_cache_update(tenant)
          _ -> :ok
        end
      end)
    else
      call(:update_migrations_ran, [external_id, count], external_id)
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

  @field_to_rate_counter_key %{
    max_events_per_second: [
      &Tenants.events_per_second_key/1,
      &Tenants.db_events_per_second_key/1
    ],
    max_joins_per_second: [
      &Tenants.joins_per_second_key/1
    ],
    max_presence_events_per_second: [
      &Tenants.presence_events_per_second_key/1
    ],
    extensions: [
      &Tenants.connect_errors_per_second_key/1,
      &Tenants.subscription_errors_per_second_key/1,
      &Tenants.authorization_errors_per_second_key/1
    ]
  }

  defp maybe_restart_rate_counters(changeset) do
    tenant_id = Changeset.fetch_field!(changeset, :external_id)

    Enum.each(@field_to_rate_counter_key, fn {field, key_fns} ->
      if Changeset.changed?(changeset, field) do
        Enum.each(key_fns, fn key_fn ->
          tenant_id
          |> key_fn.()
          |> RateCounter.publish_update()
        end)
      end
    end)
  end

  defp maybe_update_cache(tenant, %Changeset{changes: changes, valid?: true}) when changes != %{} do
    Tenants.Cache.global_cache_update(tenant)
  end

  defp maybe_update_cache(_tenant, _changeset), do: :ok

  defp maybe_trigger_disconnect(%Changeset{data: %{external_id: external_id}} = changeset)
       when requires_disconnect(changeset) do
    SocketDisconnect.distributed_disconnect(external_id)
  end

  defp maybe_trigger_disconnect(_changeset), do: nil

  defp maybe_restart_db_connection(%Changeset{data: %{external_id: external_id}} = changeset)
       when requires_restarting_db_connection(changeset) do
    Connect.shutdown(external_id)
  end

  defp maybe_restart_db_connection(_changeset), do: nil

  defp master_region? do
    region = Application.get_env(:realtime, :region)
    master_region = Application.get_env(:realtime, :master_region) || region
    region == master_region
  end

  defp call(operation, args, tenant_id) do
    master_region = Application.get_env(:realtime, :master_region)

    with {:ok, master_node} <- Nodes.node_from_region(master_region, self()),
         {:ok, result} <- wrapped_call(master_node, operation, args, tenant_id) do
      result
    end
  end

  defp wrapped_call(master_node, operation, args, tenant_id) do
    case GenRpc.call(master_node, __MODULE__, operation, args, tenant_id: tenant_id) do
      {:error, :rpc_error, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      result -> {:ok, result}
    end
  end
end
