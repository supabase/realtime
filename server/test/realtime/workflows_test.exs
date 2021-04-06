defmodule Realtime.WorkflowsTest do
  use ExUnit.Case
  use RealtimeWeb.RepoCase

  alias Realtime.Workflows

  defmodule Fixtures do
    def workflow_attrs do
      %{
        name: "Test workflow",
        trigger: "public:*",
        default_execution_type: "persistent",
        definition: %{
          "StartAt" => "Hello, World",
          "States" => %{
            "Hello, World" => %{
              "Type" => "Succeed"
            }
          }
        }
      }
    end

    def alt_workflow_attrs do
      %{
        name: "Another workflow",
        trigger: "public:users",
        default_execution_type: "transient",
        definition: %{
          "StartAt" => "Final",
          "States" => %{
            "Final" => %{
              "Type" => "Succeed"
            }
          }
        }
      }
    end

    def alternative_definition do
      %{
        "StartAt" => "Foo",
        "States" => %{
          "Foo" => %{
            "Type" => "Succeed"
          }
        }
      }
    end
  end

  describe "list_workflows" do
    test "returns an empty list if there are no workflows" do
      [] = Workflows.list_workflows()
    end

    test "returns the workflows with their definition" do
      {:ok, %{workflow: workflow}} = Workflows.create_workflow(Fixtures.workflow_attrs)
      {:ok, _} = Workflows.create_workflow(Fixtures.alt_workflow_attrs)


      # Create new revision
      {:ok, _} = Workflows.update_workflow(workflow, %{definition: Fixtures.alternative_definition})

      [workflow_1, _workflow_2] = Workflows.list_workflows()
      [revision_1] = workflow_1.revisions
      assert 1 == revision_1.version
    end
  end

  describe "create_workflow" do
    test "creates a new workflow and its first revision" do
      {:ok, %{workflow: _workflow, revision: revision}} = Workflows.create_workflow(Fixtures.workflow_attrs)

      assert 0 == revision.version
    end
  end

  describe "update_workflow" do
    test "doesn't increase revision number if the definition doesn't change" do
      {:ok, %{workflow: workflow, revision: revision}} = Workflows.create_workflow(Fixtures.workflow_attrs)

      params = %{
        name: "A new name",
        definition: revision.definition
      }

      {:ok, %{workflow: new_workflow, revision: revision}} = Workflows.update_workflow(workflow, params)

      assert 0 == revision.version
      assert "A new name" == new_workflow.name
    end

    test "doesn't increase revision number if it doesn't include a new definition" do
      {:ok, %{workflow: workflow}} = Workflows.create_workflow(Fixtures.workflow_attrs)
      {:ok, %{workflow: new_workflow, revision: revision}} = Workflows.update_workflow(workflow, %{name: "A new name"})

      assert 0 == revision.version
      assert "A new name" == new_workflow.name
    end

    test "creates a new revision if the definition changes" do
      {:ok, %{workflow: workflow}} = Workflows.create_workflow(Fixtures.workflow_attrs)

      {:ok, %{revision: revision}} = Workflows.update_workflow(workflow, %{definition: Fixtures.alternative_definition})

      assert 1 == revision.version
    end
  end

  describe "get_workflow" do
    test "returns the workflow with its most recent revision" do
      {:ok, %{workflow: workflow}} = Workflows.create_workflow(Fixtures.workflow_attrs)
      {:ok, _} = Workflows.update_workflow(workflow, %{definition: Fixtures.alternative_definition})

      workflow = Workflows.get_workflow(workflow.id)
      [revision] = workflow.revisions
      assert 1 == revision.version
    end
  end
end
