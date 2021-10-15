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

  describe "scopes" do
    alias Multiplayer.Api.Scope

    @valid_attrs %{host: "some host"}
    @update_attrs %{host: "some updated host"}
    @invalid_attrs %{host: nil}

    def scope_fixture(attrs \\ %{}) do
      {:ok, project} = Api.create_project(%{name: "project1", secret: "secret"})
      {:ok, scope} =
        attrs
        |> Map.put(:project_id, project.id)
        |> Enum.into(@valid_attrs)
        |> Api.create_scope()

      scope
    end

    test "list_scopes/0 returns all scopes" do
      scope = scope_fixture()
      assert Api.list_scopes() == [scope]
    end

    test "get_scope!/1 returns the scope with given id" do
      scope = scope_fixture()
      assert Api.get_scope!(scope.id) == scope
    end

    test "create_scope/1 with valid data creates a scope" do
      {:ok, project} = Api.create_project(%{name: "project1", secret: "secret"})
      attrs = Map.put(@valid_attrs, :project_id, project.id)
      assert {:ok, %Scope{} = scope} = Api.create_scope(attrs)
      assert scope.host == "some host"
    end

    test "create_scope/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_scope(@invalid_attrs)
    end

    test "update_scope/2 with valid data updates the scope" do
      scope = scope_fixture()
      assert {:ok, %Scope{} = scope} = Api.update_scope(scope, @update_attrs)
      assert scope.host == "some updated host"
    end

    test "update_scope/2 with invalid data returns error changeset" do
      scope = scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_scope(scope, @invalid_attrs)
      assert scope == Api.get_scope!(scope.id)
    end

    test "delete_scope/1 deletes the scope" do
      scope = scope_fixture()
      assert {:ok, %Scope{}} = Api.delete_scope(scope)
      assert_raise Ecto.NoResultsError, fn -> Api.get_scope!(scope.id) end
    end

    test "change_scope/1 returns a scope changeset" do
      scope = scope_fixture()
      assert %Ecto.Changeset{} = Api.change_scope(scope)
    end
  end

  describe "hooks" do
    alias Multiplayer.Api.Hooks

    @valid_attrs %{event: "some event", type: "some type", url: "some url"}
    @update_attrs %{event: "some updated event", type: "some updated type", url: "some updated url"}
    @invalid_attrs %{event: nil, type: nil, url: nil}

    def hooks_fixture(attrs \\ %{}) do
      {:ok, hooks} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Api.create_hooks()

      hooks
    end

    test "list_hooks/0 returns all hooks" do
      hooks = hooks_fixture()
      assert Api.list_hooks() == [hooks]
    end

    test "get_hooks!/1 returns the hooks with given id" do
      hooks = hooks_fixture()
      assert Api.get_hooks!(hooks.id) == hooks
    end

    test "create_hooks/1 with valid data creates a hooks" do
      assert {:ok, %Hooks{} = hooks} = Api.create_hooks(@valid_attrs)
      assert hooks.event == "some event"
      assert hooks.type == "some type"
      assert hooks.url == "some url"
    end

    test "create_hooks/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_hooks(@invalid_attrs)
    end

    test "update_hooks/2 with valid data updates the hooks" do
      hooks = hooks_fixture()
      assert {:ok, %Hooks{} = hooks} = Api.update_hooks(hooks, @update_attrs)
      assert hooks.event == "some updated event"
      assert hooks.type == "some updated type"
      assert hooks.url == "some updated url"
    end

    test "update_hooks/2 with invalid data returns error changeset" do
      hooks = hooks_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_hooks(hooks, @invalid_attrs)
      assert hooks == Api.get_hooks!(hooks.id)
    end

    test "delete_hooks/1 deletes the hooks" do
      hooks = hooks_fixture()
      assert {:ok, %Hooks{}} = Api.delete_hooks(hooks)
      assert_raise Ecto.NoResultsError, fn -> Api.get_hooks!(hooks.id) end
    end

    test "change_hooks/1 returns a hooks changeset" do
      hooks = hooks_fixture()
      assert %Ecto.Changeset{} = Api.change_hooks(hooks)
    end
  end
end
