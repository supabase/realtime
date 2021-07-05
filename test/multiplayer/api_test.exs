defmodule Multiplayer.ApiTest do
  use Multiplayer.DataCase

  alias Multiplayer.Api

  describe "projects" do
    alias Multiplayer.Api.Project

    @valid_attrs %{external_id: "some external_id", jwt_secret: "some jwt_secret", name: "some name"}
    @update_attrs %{external_id: "some updated external_id", jwt_secret: "some updated jwt_secret", name: "some updated name"}
    @invalid_attrs %{external_id: nil, jwt_secret: nil, name: nil}

    def project_fixture(attrs \\ %{}) do
      {:ok, project} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Api.create_project()

      project
    end

    test "list_projects/0 returns all projects" do
      project = project_fixture()
      assert Api.list_projects() == [project]
    end

    test "get_project!/1 returns the project with given id" do
      project = project_fixture()
      assert Api.get_project!(project.id) == project
    end

    test "create_project/1 with valid data creates a project" do
      assert {:ok, %Project{} = project} = Api.create_project(@valid_attrs)
      assert project.external_id == "some external_id"
      assert project.jwt_secret == "some jwt_secret"
      assert project.name == "some name"
    end

    test "create_project/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_project(@invalid_attrs)
    end

    test "update_project/2 with valid data updates the project" do
      project = project_fixture()
      assert {:ok, %Project{} = project} = Api.update_project(project, @update_attrs)
      assert project.external_id == "some updated external_id"
      assert project.jwt_secret == "some updated jwt_secret"
      assert project.name == "some updated name"
    end

    test "update_project/2 with invalid data returns error changeset" do
      project = project_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_project(project, @invalid_attrs)
      assert project == Api.get_project!(project.id)
    end

    test "delete_project/1 deletes the project" do
      project = project_fixture()
      assert {:ok, %Project{}} = Api.delete_project(project)
      assert_raise Ecto.NoResultsError, fn -> Api.get_project!(project.id) end
    end

    test "change_project/1 returns a project changeset" do
      project = project_fixture()
      assert %Ecto.Changeset{} = Api.change_project(project)
    end
  end

  describe "project_scopes" do
    alias Multiplayer.Api.ProjectScope

    @valid_attrs %{host: "some host"}
    @update_attrs %{host: "some updated host"}
    @invalid_attrs %{host: nil}

    def project_scope_fixture(attrs \\ %{}) do
      {:ok, project_scope} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Api.create_project_scope()

      project_scope
    end

    test "list_project_scopes/0 returns all project_scopes" do
      project_scope = project_scope_fixture()
      assert Api.list_project_scopes() == [project_scope]
    end

    test "get_project_scope!/1 returns the project_scope with given id" do
      project_scope = project_scope_fixture()
      assert Api.get_project_scope!(project_scope.id) == project_scope
    end

    test "create_project_scope/1 with valid data creates a project_scope" do
      assert {:ok, %ProjectScope{} = project_scope} = Api.create_project_scope(@valid_attrs)
      assert project_scope.host == "some host"
    end

    test "create_project_scope/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_project_scope(@invalid_attrs)
    end

    test "update_project_scope/2 with valid data updates the project_scope" do
      project_scope = project_scope_fixture()
      assert {:ok, %ProjectScope{} = project_scope} = Api.update_project_scope(project_scope, @update_attrs)
      assert project_scope.host == "some updated host"
    end

    test "update_project_scope/2 with invalid data returns error changeset" do
      project_scope = project_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_project_scope(project_scope, @invalid_attrs)
      assert project_scope == Api.get_project_scope!(project_scope.id)
    end

    test "delete_project_scope/1 deletes the project_scope" do
      project_scope = project_scope_fixture()
      assert {:ok, %ProjectScope{}} = Api.delete_project_scope(project_scope)
      assert_raise Ecto.NoResultsError, fn -> Api.get_project_scope!(project_scope.id) end
    end

    test "change_project_scope/1 returns a project_scope changeset" do
      project_scope = project_scope_fixture()
      assert %Ecto.Changeset{} = Api.change_project_scope(project_scope)
    end
  end
end
