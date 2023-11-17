defmodule Realtime.RepoTest do
  use Realtime.DataCase, async: false

  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Repo
  alias Realtime.Tenants.Connect

  setup do
    tenant = tenant_fixture()
    {:ok, conn} = Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(conn, "realtime.channels")
    %{conn: conn, tenant: tenant}
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
    test "fetches multiple entries and loads a given struct", %{conn: conn, tenant: tenant} do
      channel_1 = channel_fixture(tenant)
      channel_2 = channel_fixture(tenant)

      assert {:ok, [^channel_1, ^channel_2]} = Repo.all(conn, Channel, Channel)
    end
  end

  describe "one/3" do
    test "fetches one entry and loads a given struct", %{conn: conn, tenant: tenant} do
      channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)
      query = from c in Channel, where: c.id == ^channel_1.id
      assert {:ok, ^channel_1} = Repo.one(conn, query, Channel)
    end

    test "raises exception on multiple results", %{conn: conn, tenant: tenant} do
      _channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)

      assert_raise RuntimeError, "expected at most one result but got 2 in result", fn ->
        Repo.one(conn, Channel, Channel)
      end
    end

    test "if not found, returns nil", %{conn: conn} do
      query = from c in Channel, where: c.name == "potato"
      assert {:ok, nil} = Repo.one(conn, query, Channel)
    end
  end

  describe "insert/3" do
    test "inserts a new entry with a given changeset and returns struct", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, channel} = Repo.insert(conn, changeset, Channel)
      assert is_struct(channel, Channel)
    end

    test "returns changeset if changeset is invalid", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{})
      res = Repo.insert(conn, changeset, Channel)
      assert is_struct(res, Ecto.Changeset)
      assert res.valid? == false
    end

    test "returns an error on Postgrex error", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, _} = Repo.insert(conn, changeset, Channel)
      assert {:error, _} = Repo.insert(conn, changeset, Channel)
    end
  end

  describe "result_to_single_struct/2" do
    test "converts Postgrex.Result to struct" do
      timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      result =
        {:ok,
         %Postgrex.Result{
           columns: ["id", "name", "updated_at", "inserted_at"],
           rows: [[1, "foo", timestamp, timestamp]]
         }}

      metadata = metadata()

      assert {:ok,
              %Channel{
                __meta__: ^metadata,
                id: 1,
                name: "foo",
                updated_at: ^timestamp,
                inserted_at: ^timestamp
              }} = Repo.result_to_single_struct(result, Channel)
    end

    test "no results returns nil" do
      result =
        {:ok, %Postgrex.Result{columns: ["id", "name", "updated_at", "inserted_at"], rows: []}}

      assert {:ok, nil} = Repo.result_to_single_struct(result, Channel)
    end

    test "Postgrex.Result with more than one row will return error" do
      timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      result =
        {:ok,
         %Postgrex.Result{
           columns: ["id", "name", "updated_at", "inserted_at"],
           rows: [[1, "foo", timestamp, timestamp], [2, "bar", timestamp, timestamp]]
         }}

      assert_raise RuntimeError, "expected at most one result but got 2 in result", fn ->
        Repo.result_to_single_struct(result, Channel)
      end
    end
  end

  describe "result_to_structs/2" do
    test "converts Postgrex.Result to struct" do
      timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      result =
        {:ok,
         %Postgrex.Result{
           columns: ["id", "name", "updated_at", "inserted_at"],
           rows: [[1, "foo", timestamp, timestamp], [2, "bar", timestamp, timestamp]]
         }}

      assert {:ok,
              [
                %Channel{
                  id: 1,
                  name: "foo",
                  updated_at: ^timestamp,
                  inserted_at: ^timestamp
                } = channel_1,
                %Channel{
                  id: 2,
                  name: "bar",
                  updated_at: ^timestamp,
                  inserted_at: ^timestamp
                } = channel_2
              ]} = Repo.result_to_structs(result, Channel)

      assert :loaded = Ecto.get_meta(channel_1, :state)
      assert :loaded = Ecto.get_meta(channel_2, :state)
    end
  end

  describe "insert_query_from_changeset/1" do
    test "returns insert query from changeset" do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      inserted_at = changeset.changes.inserted_at
      updated_at = changeset.changes.updated_at

      expected =
        {"INSERT INTO \"realtime\".\"channels\" (\"updated_at\",\"name\",\"inserted_at\") VALUES ($1,$2,$3) RETURNING *",
         [updated_at, "foo", inserted_at]}

      assert Repo.insert_query_from_changeset(changeset) == expected
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

  defp metadata do
    %Ecto.Schema.Metadata{
      prefix: Channel.__schema__(:prefix),
      schema: Channel,
      source: Channel.__schema__(:source),
      state: :loaded
    }
  end
end
