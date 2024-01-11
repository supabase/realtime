defmodule Realtime.Tenants.TenantRepoTest do
  use Realtime.DataCase, async: false
  import Ecto.Query

  alias Realtime.Api.Channel

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Migrations
  alias Realtime.Tenants.TenantRepo

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

  describe "all/3" do
    test "fetches multiple entries and loads a given struct", %{conn: conn, tenant: tenant} do
      channel_1 = channel_fixture(tenant)
      channel_2 = channel_fixture(tenant)

      assert {:ok, [^channel_1, ^channel_2] = res} = TenantRepo.all(conn, Channel, Channel)
      assert Enum.all?(res, &(Ecto.get_meta(&1, :state) == :loaded))
    end

    test "handles exceptions", %{conn: conn} do
      Process.exit(conn, :kill)
      assert {:error, :postgrex_exception} = TenantRepo.all(conn, from(c in Channel), Channel)
    end
  end

  describe "one/3" do
    test "fetches one entry and loads a given struct", %{conn: conn, tenant: tenant} do
      channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)
      query = from c in Channel, where: c.id == ^channel_1.id
      assert {:ok, ^channel_1} = TenantRepo.one(conn, query, Channel)
      assert Ecto.get_meta(channel_1, :state) == :loaded
    end

    test "raises exception on multiple results", %{conn: conn, tenant: tenant} do
      _channel_1 = channel_fixture(tenant)
      _channel_2 = channel_fixture(tenant)

      assert_raise RuntimeError, "expected at most one result but got 2 in result", fn ->
        TenantRepo.one(conn, Channel, Channel)
      end
    end

    test "if not found, returns not found error", %{conn: conn} do
      query = from c in Channel, where: c.name == "potato"
      assert {:error, :not_found} = TenantRepo.one(conn, query, Channel)
    end

    test "handles exceptions", %{conn: conn} do
      Process.exit(conn, :kill)
      query = from c in Channel, where: c.name == "potato"
      assert {:error, :postgrex_exception} = TenantRepo.one(conn, query, Channel)
    end
  end

  describe "insert/3" do
    test "inserts a new entry with a given changeset and returns struct", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, %Channel{}} = TenantRepo.insert(conn, changeset, Channel)
    end

    test "returns changeset if changeset is invalid", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{})
      res = TenantRepo.insert(conn, changeset, Channel)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns an error on Postgrex error", %{conn: conn} do
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:ok, _} = TenantRepo.insert(conn, changeset, Channel)
      assert {:error, _} = TenantRepo.insert(conn, changeset, Channel)
    end

    test "handles exceptions", %{conn: conn} do
      Process.exit(conn, :kill)
      changeset = Channel.changeset(%Channel{}, %{name: "foo"})
      assert {:error, :postgrex_exception} = TenantRepo.insert(conn, changeset, Channel)
    end
  end

  describe "del/3" do
    test "deletes all from query entry", %{conn: conn, tenant: tenant} do
      Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(3)
      assert {:ok, 3} = TenantRepo.del(conn, Channel)
    end

    test "raises error on bad queries", %{conn: conn} do
      # wrong id type
      query = from c in Channel, where: c.id == "potato"

      assert_raise Ecto.QueryError, fn ->
        TenantRepo.del(conn, query)
      end
    end

    test "handles exceptions", %{conn: conn} do
      Process.exit(conn, :kill)
      assert {:error, :postgrex_exception} = TenantRepo.del(conn, Channel)
    end
  end

  describe "update/3" do
    test "updates a new entry with a given changeset and returns struct", %{
      conn: conn,
      tenant: tenant
    } do
      channel = channel_fixture(tenant)
      changeset = Channel.changeset(channel, %{name: "foo"})
      assert {:ok, %Channel{}} = TenantRepo.update(conn, changeset, Channel)
    end

    test "returns changeset if changeset is invalid", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      changeset = Channel.changeset(channel, %{name: 0})
      res = TenantRepo.update(conn, changeset, Channel)
      assert {:error, %Ecto.Changeset{valid?: false}} = res
    end

    test "returns an error on Postgrex error", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      channel_to_update = channel_fixture(tenant)

      changeset = Channel.changeset(channel_to_update, %{name: channel.name})
      assert {:error, _} = TenantRepo.update(conn, changeset, Channel)
    end

    test "handles exceptions", %{tenant: tenant, conn: conn} do
      changeset = Channel.changeset(channel_fixture(tenant), %{name: "foo"})
      Process.exit(conn, :kill)
      assert {:error, :postgrex_exception} = TenantRepo.update(conn, changeset, Channel)
    end
  end
end
