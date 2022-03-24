defmodule Multiplayer.Api do
  @moduledoc """
  The Api context.
  """

  import Ecto.Query, warn: false
  alias Multiplayer.Repo

  alias Multiplayer.Api.Tenant

  @doc """
  Returns the list of tenants.

  ## Examples

      iex> list_tenants()
      [%Tenant{}, ...]

  """
  def list_tenants do
    Repo.all(Tenant)
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

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking tenant changes.

  ## Examples

      iex> change_tenant(tenant)
      %Ecto.Changeset{data: %Tenant{}}

  """
  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end

  alias Multiplayer.Api.Scope

  @doc """
  Returns the list of scopes.

  ## Examples

      iex> list_scopes()
      [%Scope{}, ...]

  """
  def list_scopes do
    Repo.all(Scope)
  end

  @doc """
  Gets a single scope.

  Raises `Ecto.NoResultsError` if the Scope does not exist.

  ## Examples

      iex> get_scope!(123)
      %Scope{}

      iex> get_scope!(456)
      ** (Ecto.NoResultsError)

  """
  def get_scope!(id), do: Repo.get!(Scope, id)

  @doc """
  Creates a scope.

  ## Examples

      iex> create_scope(%{field: value})
      {:ok, %Scope{}}

      iex> create_scope(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_scope(attrs \\ %{}) do
    %Scope{}
    |> Scope.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a scope.

  ## Examples

      iex> update_scope(scope, %{field: new_value})
      {:ok, %Scope{}}

      iex> update_scope(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_scope(%Scope{} = scope, attrs) do
    scope
    |> Scope.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a scope.

  ## Examples

      iex> delete_scope(scope)
      {:ok, %Scope{}}

      iex> delete_scope(scope)
      {:error, %Ecto.Changeset{}}

  """
  def delete_scope(%Scope{} = scope) do
    Repo.delete(scope)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking scope changes.

  ## Examples

      iex> change_scope(scope)
      %Ecto.Changeset{data: %Scope{}}

  """
  def change_scope(%Scope{} = scope, attrs \\ %{}) do
    Scope.changeset(scope, attrs)
  end

  def get_tenant_by_host(host) do
    query =
      from(s in Scope,
        join: p in Tenant,
        on: s.tenant_id == p.id,
        where: s.host == ^host and s.active == true and p.active == true,
        select: p
      )

    Repo.one(query)
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
  end

  alias Multiplayer.Api.Hooks

  @doc """
  Returns the list of hooks.

  ## Examples

      iex> list_hooks()
      [%Hooks{}, ...]

  """
  def list_hooks do
    Repo.all(Hooks)
  end

  @doc """
  Gets a single hooks.

  Raises `Ecto.NoResultsError` if the Hooks does not exist.

  ## Examples

      iex> get_hooks!(123)
      %Hooks{}

      iex> get_hooks!(456)
      ** (Ecto.NoResultsError)

  """
  def get_hooks!(id), do: Repo.get!(Hooks, id)

  def get_hooks_by_tenant_id(id) do
    query =
      from(h in Hooks,
        where: h.tenant_id == ^id,
        select: h
      )

    Enum.reduce(Repo.all(query), %{}, fn e, acc ->
      hook = %{
        type: e.type,
        url: e.url
      }

      Map.put(acc, e.event, hook)
    end)
  end

  @doc """
  Creates a hooks.

  ## Examples

      iex> create_hooks(%{field: value})
      {:ok, %Hooks{}}

      iex> create_hooks(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_hooks(attrs \\ %{}) do
    %Hooks{}
    |> Hooks.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a hooks.

  ## Examples

      iex> update_hooks(hooks, %{field: new_value})
      {:ok, %Hooks{}}

      iex> update_hooks(hooks, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_hooks(%Hooks{} = hooks, attrs) do
    hooks
    |> Hooks.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a hooks.

  ## Examples

      iex> delete_hooks(hooks)
      {:ok, %Hooks{}}

      iex> delete_hooks(hooks)
      {:error, %Ecto.Changeset{}}

  """
  def delete_hooks(%Hooks{} = hooks) do
    Repo.delete(hooks)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking hooks changes.

  ## Examples

      iex> change_hooks(hooks)
      %Ecto.Changeset{data: %Hooks{}}

  """
  def change_hooks(%Hooks{} = hooks, attrs \\ %{}) do
    Hooks.changeset(hooks, attrs)
  end
end
