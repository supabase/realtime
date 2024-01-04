defmodule Realtime.RepoTest do
  use Realtime.DataCase, async: false

  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Repo
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Migrations

  @cdc "postgres_cdc_rls"

  setup do
    tenant = tenant_fixture()
    {:ok, conn} = Connect.lookup_or_start_connection(tenant.external_id)

    settings = Realtime.PostgresCdc.filter_settings(@cdc, tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Migrations, settings})
    clean_table(conn, "realtime", "channels")
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

      assert {:ok, [^channel_1, ^channel_2] = res} = Repo.all(conn, Channel, Channel)
      assert Enum.all?(res, &(Ecto.get_meta(&1, :state) == :loaded))
    end
  end

  describe "one/3" do
    test "fetches one entry and loads a given struct", %{conn: conn, tenant: tenant} do
      channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)
      query = from c in Channel, where: c.id == ^channel_1.id
      assert {:ok, ^channel_1} = Repo.one(conn, query, Channel)
      assert Ecto.get_meta(channel_1, :state) == :loaded
    end

    test "raises exception on multiple results", %{conn: conn, tenant: tenant} do
      _channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)

      assert_raise RuntimeError, "expected at most one result but got 2 in result", fn ->
        Repo.one(conn, Channel, Channel)
      end
    end

    test "if not found, returns not found error", %{conn: conn} do
      query = from c in Channel, where: c.name == "potato"
      assert {:error, :not_found} = Repo.one(conn, query, Channel)
    end
  end

  describe "insert/3" do
    test "inserts a new entry with a given changeset and returns struct", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, %Channel{}} = Repo.insert(conn, changeset, Channel)
    end

    test "returns changeset if changeset is invalid", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{})
      res = Repo.insert(conn, changeset, Channel)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns an error on Postgrex error", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, _} = Repo.insert(conn, changeset, Channel)
      assert {:error, _} = Repo.insert(conn, changeset, Channel)
    end
  end

  describe "del/3" do
    test "deletes all from query entry", %{conn: conn, tenant: tenant} do
      Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(3)
      assert {:ok, 3} = Repo.del(conn, Channel)
    end

    test "raises error on bad queries", %{conn: conn} do
      # wrong id type
      query = from c in Channel, where: c.id == "potato"

      assert_raise Ecto.QueryError, fn ->
        Repo.del(conn, query)
      end
    end
  end

  describe "update/3" do
    test "updates a new entry with a given changeset and returns struct", %{
      conn: conn,
      tenant: tenant
    } do
      channel = channel_fixture(tenant)
      changeset = Channel.changeset(channel, %{name: "foo"})
      assert {:ok, %Channel{}} = Repo.update(conn, changeset, Channel)
    end

    test "returns changeset if changeset is invalid", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      changeset = Channel.changeset(channel, %{name: 0})
      res = Repo.update(conn, changeset, Channel)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns an error on Postgrex error", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      channel_to_update = channel_fixture(tenant)

      changeset = Channel.changeset(channel_to_update, %{name: channel.name})
      assert {:error, _} = Repo.update(conn, changeset, Channel)
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
