defmodule Realtime.RepoTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Ecto.Query

  alias Realtime.Api.Message
  alias Realtime.Crypto
  alias Realtime.Repo
  alias Realtime.Database
  alias Realtime.Tenants.Connect

  setup do
    tenant = tenant_fixture()

    {:ok, _} = start_supervised({Connect, tenant_id: tenant.external_id}, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    clean_table(db_conn, "realtime", "messages")

    %{db_conn: db_conn, tenant: tenant}
  end

  describe "with_dynamic_repo/2" do
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

  describe "all/3" do
    test "fetches multiple entries and loads a given struct", %{db_conn: db_conn, tenant: tenant} do
      message_1 = message_fixture(tenant)
      message_2 = message_fixture(tenant)

      assert {:ok, [^message_1, ^message_2] = res} = Repo.all(db_conn, Message, Message)
      assert Enum.all?(res, &(Ecto.get_meta(&1, :state) == :loaded))
    end

    test "handles exceptions", %{db_conn: db_conn} do
      Process.unlink(db_conn)
      Process.exit(db_conn, :kill)

      assert {:error, :postgrex_exception} = Repo.all(db_conn, from(c in Message), Message)
    end
  end

  describe "one/3" do
    test "fetches one entry and loads a given struct", %{db_conn: db_conn, tenant: tenant} do
      message_1 = message_fixture(tenant)
      _message_2 = message_fixture(tenant)
      query = from c in Message, where: c.id == ^message_1.id
      assert {:ok, ^message_1} = Repo.one(db_conn, query, Message)
      assert Ecto.get_meta(message_1, :state) == :loaded
    end

    test "raises exception on multiple results", %{db_conn: db_conn, tenant: tenant} do
      _message_1 = message_fixture(tenant)
      _message_2 = message_fixture(tenant)

      assert_raise RuntimeError, "expected at most one result but got 2 in result", fn ->
        Repo.one(db_conn, Message, Message)
      end
    end

    test "if not found, returns not found error", %{db_conn: db_conn} do
      query = from c in Message, where: c.topic == "potato"
      assert {:error, :not_found} = Repo.one(db_conn, query, Message)
    end

    test "handles exceptions", %{db_conn: db_conn} do
      Process.unlink(db_conn)
      Process.exit(db_conn, :kill)
      query = from c in Message, where: c.topic == "potato"
      assert {:error, :postgrex_exception} = Repo.one(db_conn, query, Message)
    end
  end

  describe "insert/3" do
    test "inserts a new entry with a given changeset and returns struct", %{db_conn: db_conn} do
      changeset = Message.changeset(%Message{}, %{topic: "foo", extension: :presence})

      assert {:ok, %Message{}} = Repo.insert(db_conn, changeset, Message)
    end

    test "returns changeset if changeset is invalid", %{db_conn: db_conn} do
      changeset = Message.changeset(%Message{}, %{})
      res = Repo.insert(db_conn, changeset, Message)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns a Changeset on Changeset error", %{db_conn: db_conn} do
      changeset = Message.changeset(%Message{}, %{})

      assert {:error,
              %Ecto.Changeset{
                valid?: false,
                errors: [
                  topic: {"can't be blank", [validation: :required]},
                  extension: {"can't be blank", [validation: :required]}
                ]
              }} =
               Repo.insert(db_conn, changeset, Message)
    end

    test "handles exceptions", %{db_conn: db_conn} do
      Process.unlink(db_conn)
      Process.exit(db_conn, :kill)

      changeset = Message.changeset(%Message{}, %{topic: "foo", extension: :presence})

      assert {:error, :postgrex_exception} = Repo.insert(db_conn, changeset, Message)
    end
  end

  describe "del/3" do
    test "deletes all from query entry", %{db_conn: db_conn, tenant: tenant} do
      Stream.repeatedly(fn -> message_fixture(tenant) end) |> Enum.take(3)
      assert {:ok, 3} = Repo.del(db_conn, Message)
    end

    test "raises error on bad queries", %{db_conn: db_conn} do
      # wrong id type
      query = from c in Message, where: c.id == "potato"

      assert_raise Ecto.QueryError, fn ->
        Repo.del(db_conn, query)
      end
    end

    test "handles exceptions", %{db_conn: db_conn} do
      Process.unlink(db_conn)
      Process.exit(db_conn, :kill)

      assert {:error, :postgrex_exception} = Repo.del(db_conn, Message)
    end
  end

  describe "update/3" do
    test "updates a new entry with a given changeset and returns struct", %{
      db_conn: db_conn,
      tenant: tenant
    } do
      message = message_fixture(tenant)
      changeset = Message.changeset(message, %{topic: "foo"})
      assert {:ok, %Message{}} = Repo.update(db_conn, changeset, Message)
    end

    test "returns changeset if changeset is invalid", %{db_conn: db_conn, tenant: tenant} do
      message = message_fixture(tenant)
      changeset = Message.changeset(message, %{topic: 0})
      res = Repo.update(db_conn, changeset, Message)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns an Changeset on Changeset error", %{db_conn: db_conn, tenant: tenant} do
      message_to_update = message_fixture(tenant)

      changeset = Message.changeset(message_to_update, %{topic: nil})

      assert {:error,
              %Ecto.Changeset{
                valid?: false,
                errors: [topic: {"can't be blank", [validation: :required]}]
              }} = Repo.update(db_conn, changeset, Message)
    end

    test "handles exceptions", %{tenant: tenant, db_conn: db_conn} do
      changeset = Message.changeset(message_fixture(tenant), %{topic: "foo"})

      Process.unlink(db_conn)
      Process.exit(db_conn, :kill)

      assert {:error, :postgrex_exception} = Repo.update(db_conn, changeset, Message)
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
      Crypto.decrypt_creds(
        db_host,
        db_port,
        db_name,
        db_user,
        db_password
      )

    ssl_enforced = Database.default_ssl_param(args)

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
