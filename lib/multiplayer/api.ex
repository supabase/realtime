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

      iex> get_project!(123)
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

  alias Multiplayer.Api.ProjectScope

  @doc """
  Returns the list of project_scopes.

  ## Examples

      iex> list_project_scopes()
      [%ProjectScope{}, ...]

  """
  def list_project_scopes do
    Repo.all(ProjectScope)
  end

  @doc """
  Gets a single project_scope.

  Raises `Ecto.NoResultsError` if the Project scope does not exist.

  ## Examples

      iex> get_project_scope!(123)
      %ProjectScope{}

      iex> get_project_scope!(456)
      ** (Ecto.NoResultsError)

  """
  def get_project_scope!(id), do: Repo.get!(ProjectScope, id)

  @doc """
  Creates a project_scope.

  ## Examples

      iex> create_project_scope(%{field: value})
      {:ok, %ProjectScope{}}

      iex> create_project_scope(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project_scope(attrs \\ %{}) do
    %ProjectScope{}
    |> ProjectScope.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a project_scope.

  ## Examples

      iex> update_project_scope(project_scope, %{field: new_value})
      {:ok, %ProjectScope{}}

      iex> update_project_scope(project_scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project_scope(%ProjectScope{} = project_scope, attrs) do
    project_scope
    |> ProjectScope.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project_scope.

  ## Examples

      iex> delete_project_scope(project_scope)
      {:ok, %ProjectScope{}}

      iex> delete_project_scope(project_scope)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project_scope(%ProjectScope{} = project_scope) do
    Repo.delete(project_scope)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project_scope changes.

  ## Examples

      iex> change_project_scope(project_scope)
      %Ecto.Changeset{data: %ProjectScope{}}

  """
  def change_project_scope(%ProjectScope{} = project_scope, attrs \\ %{}) do
    ProjectScope.changeset(project_scope, attrs)
  end
end
