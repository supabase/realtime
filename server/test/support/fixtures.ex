defmodule RealtimeWeb.Fixtures do
  @moduledoc """
  This module defines the test case to be used by
  tests that require fixtures.
  """

  def workflow do
    quote do
      @state_machine_definition %{
        "Comment": "A simple minimal example of the States language",
        "StartAt": "StartHere",
        "States": %{
          "StartHere": %{
            "Type": "Wait",
            "Seconds": 1,
            "Next": "EndHere"
          },
          "EndHere": %{
            "Type": "Task",
            "Resource": "https://www.example.org",
            "End": true
          }
        }
      }

      @workflow_attrs %{
        name: "Test workflow",
        trigger: "public:users",
        default_execution_type: "transient",
        default_log_type: "none",
        definition: @state_machine_definition
      }

      def workflow_fixture(attrs \\ %{}) do
        Enum.into(attrs, @workflow_attrs)
      end

      def state_machine_definition_fixture(attrs \\ %{}) do
        Enum.into(attrs, @state_machine_definition)
      end
    end
  end

  def execution do
    quote do
      @execution_attrs %{
        arguments: %{
          "a" => 1,
          "b" => 2
        },
        log_type: "none",
        start_state: "EndHere"
      }

      def execution_fixture(attrs \\ %{}) do
        Enum.into(attrs, @execution_attrs)
      end
    end
  end

  defmacro __using__(fixtures) when is_list(fixtures) do
    for fixture <- fixtures, is_atom(fixture),
        do: apply(__MODULE__, fixture, [])
  end
end
