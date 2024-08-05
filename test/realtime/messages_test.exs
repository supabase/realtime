defmodule Realtime.MessagesTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Messages

  setup do
    tenant = tenant_fixture()
    {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
    clean_table(conn, "realtime", "messages")
    on_exit(fn -> Process.exit(conn, :normal) end)
    %{conn: conn, tenant: tenant}
  end

  describe "create_message/2" do
    test "creates a message",
         %{conn: conn} do
      topic = random_string()
      extension = Enum.random([:broadcast, :presence])
      params = %{topic: topic, extension: extension}
      assert {:ok, %Message{topic: ^topic}} = Messages.create_message(params, conn)
    end

    test "ensure message has topic, extension", %{conn: conn} do
      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} =
               Messages.create_message(%{}, conn)

      assert ^errors = [
               topic: {"can't be blank", [validation: :required]},
               extension: {"can't be blank", [validation: :required]}
             ]
    end
  end
end
