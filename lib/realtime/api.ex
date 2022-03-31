defmodule Realtime.Api do
  @moduledoc """
  The Api context.
  """
  require Logger

  import Ecto.Query, warn: false
  alias Realtime.Repo

  alias Realtime.Api.Tenant

  @doc """
  Returns the list of tenants.

  ## Examples

      iex> list_tenants()
      [%Tenant{}, ...]

  """
  def list_tenants do
    Repo.all(Tenant) |> Repo.preload(:extensions)
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
  def get_tenant!(id), do: Repo.get!(Tenant, id)

  @doc """
  Creates a tenant.

  ## Examples

      iex> create_tenant(%{field: value})
      {:ok, %Tenant{}}

      iex> create_tenant(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_tenant(attrs \\ %{}) do
    Logger.debug("create_tenant #{inspect(attrs, pretty: true)}")

    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:extensions, attrs["extensions"])
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

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking tenant changes.

  ## Examples

      iex> change_tenant(tenant)
      %Ecto.Changeset{data: %Tenant{}}

  """
  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end

  def get_tenant_by_name(name) do
    query =
      from(p in Tenant,
        where: p.name == ^name,
        select: p
      )

    Repo.one(query)
  end

  def get_tenant_by_external_id(:cached, external_id) do
    with {:commit, val} <- Cachex.fetch(:tenants, external_id, &get_tenant_by_external_id/1) do
      Cachex.expire(:tenants, external_id, :timer.seconds(500))
      val
    else
      {:ok, val} ->
        val

      _ ->
        :error
    end
  end

  def get_tenant_by_external_id(external_id) do
    query =
      from(p in Tenant,
        where: p.external_id == ^external_id,
        select: p
      )

    Repo.one(query)
    |> Repo.preload(:extensions)
  end
end
