defmodule Multiplayer.Api do
  @moduledoc """
  The Api context.
  """

  import Ecto.Query, warn: false
  alias Multiplayer.Repo

  alias Multiplayer.Api.Project

  @doc """
  Returns the list of projects.

  ## Examples

      iex> list_projects()
      [%Project{}, ...]

  """
  def list_projects do
    Repo.all(Project)
  end

  @doc """
  Gets a single project.

  Raises `Ecto.NoResultsError` if the Project does not exist.

  ## Examples

      iex> _by_host!(123) do

      end

      %Project{}

      iex> get_project!(456)
      ** (Ecto.NoResultsError)

  """
  def get_project!(id), do: Repo.get!(Project, id)

  @doc """
  Creates a project.

  ## Examples

      iex> create_project(%{field: value})
      {:ok, %Project{}}

      iex> create_project(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a project.

  ## Examples

      iex> update_project(project, %{field: new_value})
      {:ok, %Project{}}

      iex> update_project(project, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project.

  ## Examples

      iex> delete_project(project)
      {:ok, %Project{}}

      iex> delete_project(project)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project changes.

  ## Examples

      iex> change_project(project)
      %Ecto.Changeset{data: %Project{}}

  """
  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
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

  def get_project_by_host(host) do
    query = from s in Scope,
              join: p in Project,
              on: s.project_id == p.id,
              where: s.host == ^host,
              select: p
    Repo.one(query)
  end

  def get_project_by_name(name) do
    query = from p in Project,
              where: p.name == ^name,
              select: p
    Repo.one(query)
  end

  def get_project_by_external_id(external_id) do
    query = from p in Project,
              where: p.external_id == ^external_id,
              select: p
    Repo.one(query)
  end

end
