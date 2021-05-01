defmodule RealtimeWeb.ExecutionControllerTest do
  use RealtimeWeb.ConnCase
  use RealtimeWeb.RepoCase
  use RealtimeWeb.Fixtures, [:workflow, :execution]

  describe "index" do
    test "list all workflow's executions", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      conn = get(conn, Routes.workflow_execution_path(conn, :index, workflow_id))
      assert [] = json_response(conn, 200)["executions"]

      conn = post(conn, Routes.workflow_execution_path(conn, :create, workflow_id), execution_fixture())
      json_response(conn, 201)

      conn = get(conn, Routes.workflow_execution_path(conn, :index, workflow_id))
      assert [%{"arguments" => _}] = json_response(conn, 200)["executions"]
    end
  end

  describe "create" do
    test "returns the workflow execution together with its result", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      conn = post(conn, Routes.workflow_execution_path(conn, :create, workflow_id), execution_fixture())
      assert %{"execution" => execution, "result" => result} = json_response(conn, 201)

      assert %{
               "id" => execution_id
             } = execution

      conn = get(conn, Routes.workflow_execution_path(conn, :show, workflow_id, execution_id))

      assert %{
               "id" => workflow_id,
             } = json_response(conn, 200)["execution"]
    end

    test "returns an error if a required field is missing", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      attrs = execution_fixture(%{arguments: nil})
      conn = post(conn, Routes.workflow_execution_path(conn, :create, workflow_id), attrs)
      assert %{"errors" => %{"arguments" => ["can't be blank"]}} = json_response(conn, 400)
    end

  end

  describe "show" do
    test "returns 404 if the execution does not exist", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      conn = get(conn, Routes.workflow_execution_path(conn, :show, workflow_id, "da56c89b-f811-4bdc-b009-ee62e23712b4"))
      json_response(conn, 404)
    end
  end

  describe "delete" do
    test "returns the newly deleted execution", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      conn = post(conn, Routes.workflow_execution_path(conn, :create, workflow_id), execution_fixture())
      assert %{"id" => execution_id} = json_response(conn, 201)["execution"]

      conn = delete(conn, Routes.workflow_execution_path(conn, :delete, workflow_id, execution_id))
      assert %{
               "arguments" => _
             } = json_response(conn, 200)["execution"]

      conn = get(conn, Routes.workflow_execution_path(conn, :show, workflow_id, execution_id))
      json_response(conn, 404)
    end

    test "returns 404 if the execution does not exist", %{conn: conn} do
      workflow_id = insert_workflow(conn)

      conn = delete(conn, Routes.workflow_execution_path(conn, :delete, workflow_id, "da56c89b-f811-4bdc-b009-ee62e23712b4"))
      json_response(conn, 404)
    end
  end

  defp insert_workflow(conn) do
    workflow = workflow_fixture()
    conn = post(conn, Routes.workflow_path(conn, :create), workflow)
    assert %{"id" => workflow_id} = json_response(conn, 201)["workflow"]
    workflow_id
  end
end
