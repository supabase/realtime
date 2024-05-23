defmodule Realtime.ChannelsTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  alias Realtime.Api.Message
  alias Realtime.Messages
  alias Realtime.Tenants.Connect

  setup do
    tenant = tenant_fixture()

    {:ok, pid} = Connect.connect(tenant.external_id)
    Process.link(pid)
    {:ok, conn} = Connect.get_status(tenant.external_id)

    clean_table(conn, "realtime", "messages")

    on_exit(fn -> Process.exit(conn, :normal) end)
    %{conn: conn, tenant: tenant}
  end

  describe "create_message/2" do
    test "creates a message",
         %{conn: conn} do
      channel_name = random_string()
      event = random_string()
      feature = Enum.random([:broadcast, :presence])
      params = %{channel_name: channel_name, feature: feature, event: event}
      assert {:ok, %Message{channel_name: ^channel_name}} = Messages.create_message(params, conn)
    end

    test "ensure message has channel_name, feature and event", %{conn: conn} do
      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} =
               Messages.create_message(%{}, conn)

      assert ^errors = [
               channel_name: {"can't be blank", [validation: :required]},
               feature: {"can't be blank", [validation: :required]},
               event: {"can't be blank", [validation: :required]}
             ]
    end
  end
end
