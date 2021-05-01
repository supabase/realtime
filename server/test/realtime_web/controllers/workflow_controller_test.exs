defmodule RealtimeWeb.WorkflowControllerTest do
  use RealtimeWeb.ConnCase
  use RealtimeWeb.RepoCase

  @create_attrs %{
    name: "Test workflow",
    trigger: "public:users",
    default_execution_type: "transient",
    definition: %{
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
  }

  describe "index" do
    test "list all workflows", %{conn: conn} do
      conn = get(conn, Routes.workflow_path(conn, :index))
      assert [] = json_response(conn, 200)["workflows"]

      conn = post(conn, Routes.workflow_path(conn, :create), @create_attrs)
      json_response(conn, 201)

      conn = get(conn, Routes.workflow_path(conn, :index))
      assert [%{"name" => _, "definition" => definition}] = json_response(conn, 200)["workflows"]
      assert not Enum.empty?(definition)
    end
  end

  describe "create" do
    test "returns the newly created workflow when valid", %{conn: conn} do
      conn = post(conn, Routes.workflow_path(conn, :create), @create_attrs)
      assert %{"id" => workflow_id} = json_response(conn, 201)["workflow"]

      conn = get(conn, Routes.workflow_path(conn, :show, workflow_id))
      assert %{
               "id" => workflow_id,
             } = json_response(conn, 200)["workflow"]
    end

    test "returns an error if a required field is missing", %{conn: conn} do
      missing_name = %{@create_attrs | name: nil}
      conn = post(conn, Routes.workflow_path(conn, :create), missing_name)
      assert %{"errors" => %{"name" => ["can't be blank"]}} = json_response(conn, 400)

      missing_trigger = %{@create_attrs | trigger: nil}
      conn = post(conn, Routes.workflow_path(conn, :create), missing_trigger)
      assert %{"errors" => %{"trigger" => ["can't be blank"]}} = json_response(conn, 400)

      missing_default_execution_type = %{@create_attrs | default_execution_type: nil}
      conn = post(conn, Routes.workflow_path(conn, :create), missing_default_execution_type)
      assert %{"errors" => %{"default_execution_type" => ["can't be blank"]}} = json_response(conn, 400)

      missing_definition = %{@create_attrs | definition: nil}
      conn = post(conn, Routes.workflow_path(conn, :create), missing_definition)
      assert %{"errors" => %{"definition" => ["can't be blank"]}} = json_response(conn, 400)
    end

    test "returns an error if the default_execution_type is invalid", %{conn: conn} do
      # First check create returns new workflow with correct default_execution_type values
      default_execution_type_transient =
        %{@create_attrs | default_execution_type: "transient", name: "Execution Type 1"}
      conn = post(conn, Routes.workflow_path(conn, :create), default_execution_type_transient)
      assert %{"workflow" => _} = json_response(conn, 201)

      default_execution_type_persistent =
        %{@create_attrs | default_execution_type: "persistent", name: "Execution Type 2"}
      conn = post(conn, Routes.workflow_path(conn, :create), default_execution_type_persistent)
      assert %{"workflow" => _} = json_response(conn, 201)

      default_execution_type_invalid = %{@create_attrs | default_execution_type: "magic"}
      conn = post(conn, Routes.workflow_path(conn, :create), default_execution_type_invalid)
      assert %{"errors" => %{"default_execution_type" => ["is invalid"]}} = json_response(conn, 400)
    end

    @tag :skip
    # TODO: need to validate workflows definition in package
    test "returns an error if the definition is invalid", %{conn: conn} do
      # The StartAt field is required by the spec
      invalid_definition = %{@create_attrs[:definition] | "StartAt": nil}
      invalid_attrs = %{@create_attrs | definition: invalid_definition}
      conn = post(conn, Routes.workflow_path(conn, :create), invalid_attrs)
      assert %{"errors" => %{"definition" => ["is invalid"]}} = json_response(conn, 400)
    end

    test "returns an error if the trigger is invalid", %{conn: conn} do
      invalid_attrs = %{@create_attrs | trigger: "::::"}
      conn = post(conn, Routes.workflow_path(conn, :create), invalid_attrs)
      assert %{"errors" => %{"trigger" => ["is invalid"]}} = json_response(conn, 400)
    end
  end

  describe "show" do
    test "returns 404 if the workflow does not exist", %{conn: conn} do
      conn = get(conn, Routes.workflow_path(conn, :show, "da56c89b-f811-4bdc-b009-ee62e23712b4"))
      json_response(conn, 404)
    end
  end

  describe "update" do
    test "returns the newly updated workflow when valid", %{conn: conn} do
      conn = post(conn, Routes.workflow_path(conn, :create), @create_attrs)
      assert %{"id" => workflow_id} = json_response(conn, 201)["workflow"]

      update_attrs = %{@create_attrs | name: "The new name"}
      conn = put(conn, Routes.workflow_path(conn, :update, workflow_id), update_attrs)
      assert %{
               "id" => workflow_id,
               "name" => "The new name"
             } = json_response(conn, 200)["workflow"]
    end

    test "does not update the workflow if validation fails", %{conn: conn} do
      conn = post(conn, Routes.workflow_path(conn, :create), @create_attrs)
      assert %{"id" => workflow_id} = json_response(conn, 201)["workflow"]

      update_attrs = %{@create_attrs | name: "U"}
      conn = put(conn, Routes.workflow_path(conn, :update, workflow_id), update_attrs)
      assert %{"errors" => %{"name" => [_]}} = json_response(conn, 400)

      conn = get(conn, Routes.workflow_path(conn, :show, workflow_id))
      assert %{
               "name" => "Test workflow"
             } = json_response(conn, 200)["workflow"]
    end

    test "returns 404 if the workflow does not exist", %{conn: conn} do
      conn = put(conn, Routes.workflow_path(conn, :update, "da56c89b-f811-4bdc-b009-ee62e23712b4"), @create_attrs)
      json_response(conn, 404)
    end
  end

  describe "delete" do
    test "returns the newly deleted workflow", %{conn: conn} do
      conn = post(conn, Routes.workflow_path(conn, :create), @create_attrs)
      assert %{"id" => workflow_id} = json_response(conn, 201)["workflow"]

      conn = delete(conn, Routes.workflow_path(conn, :delete, workflow_id))
      assert %{
               "name" => "Test workflow"
             } = json_response(conn, 200)["workflow"]

      conn = get(conn, Routes.workflow_path(conn, :show, workflow_id))
      json_response(conn, 404)
    end

    test "returns 404 if the workflow does not exist", %{conn: conn} do
      conn = delete(conn, Routes.workflow_path(conn, :delete, "da56c89b-f811-4bdc-b009-ee62e23712b4"))
      json_response(conn, 404)
    end
  end
end
