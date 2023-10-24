defmodule Realtime.RepoTest do
  use Realtime.DataCase, async: false
  alias Realtime.Repo

  describe "with_dynamic_repo" do
    test "starts a repo with the given config and kills it in the end of the command" do
      test_pid = self()

      Repo.with_dynamic_repo(db_config(), fn repo ->
        Ecto.Adapters.SQL.query(repo, "SELECT 1", [])
        send(test_pid, repo)
        send(test_pid, :query_success)
      end)

      repo_pid =
        receive do
          repo_pid -> repo_pid
        end

      assert_receive :query_success
      assert Process.alive?(repo_pid) == false
    end

    test "kills repo pid when we kill parent pid" do
      test_pid = self()

      parent_pid =
        spawn(fn ->
          Repo.with_dynamic_repo(db_config(), fn repo ->
            send(test_pid, repo)
            Ecto.Adapters.SQL.query(repo, "SELECT pg_sleep(1)", [])
            raise("Should not run query")
          end)
        end)

      repo_pid =
        receive do
          repo_pid -> repo_pid
        end

      true = Process.exit(parent_pid, :kill)
      :timer.sleep(1500)
      assert Process.alive?(repo_pid) == false
    end

    test "concurrent repos can coexist" do
      test_pid = self()

      pid_1 =
        spawn(fn ->
          Repo.with_dynamic_repo(db_config(), fn repo ->
            send(test_pid, repo)
            Ecto.Adapters.SQL.query(repo, "SELECT pg_sleep(1)", [])
            send(test_pid, :query_success)
          end)
        end)

      pid_2 =
        spawn(fn ->
          Repo.with_dynamic_repo(db_config(), fn repo ->
            send(test_pid, repo)
            Ecto.Adapters.SQL.query(repo, "SELECT pg_sleep(1)", [])
            send(test_pid, :query_success)
          end)
        end)

      repo_pid_1 =
        receive do
          repo_pid -> repo_pid
        end

      repo_pid_2 =
        receive do
          repo_pid -> repo_pid
        end

      assert Process.alive?(repo_pid_1) == true
      assert Process.alive?(repo_pid_2) == true

      assert_receive :query_success, 2000
      assert_receive :query_success, 2000

      :timer.sleep(100)
      assert Process.alive?(repo_pid_1) == false
      assert Process.alive?(repo_pid_2) == false
      assert Process.alive?(pid_1) == false
      assert Process.alive?(pid_2) == false
    end

    test "on exception from query" do
      test_pid = self()

      try do
        spawn(fn ->
          Repo.with_dynamic_repo(db_config(), fn repo ->
            send(test_pid, repo)
            :timer.sleep(100)
            raise "💣"
          end)
        end)
      catch
        _ -> :ok
      end

      repo_pid =
        receive do
          repo_pid -> repo_pid
        end

      assert Process.alive?(repo_pid) == true
      :timer.sleep(300)
      assert Process.alive?(repo_pid) == false
    end
  end

  defp db_config() do
    tenant = tenant_fixture()

    %{
      "db_host" => db_host,
      "db_name" => db_name,
      "db_password" => db_password,
      "db_port" => db_port,
      "db_user" => db_user
    } = args = tenant.extensions |> hd() |> then(& &1.settings)

    {host, port, name, user, pass} =
      Realtime.Helpers.decrypt_creds(
        db_host,
        db_port,
        db_name,
        db_user,
        db_password
      )

    ssl_enforced = Realtime.Helpers.default_ssl_param(args)

    [
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      ssl_enforced: ssl_enforced
    ]
  end
end
