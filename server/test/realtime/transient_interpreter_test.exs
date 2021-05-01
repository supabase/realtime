defmodule Realtime.TransientInterpreterTest do
  use ExUnit.Case
  use RealtimeWeb.RepoCase

  alias Realtime.Workflows
  alias Realtime.Interpreter

  defmodule Fixtures do
    def workflow_definition do
      %{
        "StartAt" => "WaitThree",
        "States" => %{
          "WaitThree" => %{
            "Type" => "Wait",
            "Seconds" => 3,
            "Next" => "DoSomething"
          },
          "DoSomething" => %{
            "Type" => "Task",
            "Resource" => "realtime:do-something",
            "Next" => "Done"
          },
          "Done" => %{
            "Type" => "Succeed"
          }
        }
      }
    end

    def workflow_attrs do
      %{
        name: "Test Workflow",
        trigger: "*",
        default_execution_type: "transient",
        definition: workflow_definition()
      }
    end

    def execution_attrs do
      %{
        arguments: %{
          "Number" => 123,
          "String" => "A string"
        }
      }
    end
  end

  test "starts the interpreter as task" do
    {:ok, %{workflow: workflow}} = Workflows.create_workflow(Fixtures.workflow_attrs)
    {:ok, %{execution: execution, revision: revision}} = Workflows.create_workflow_execution(
      workflow.id,
      Fixtures.execution_attrs()
    )

    {:ok, pid} = Interpreter.start_transient(workflow, execution, revision)
    assert is_pid(pid)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, _, ^pid, _} -> nil
    end
  end
end
