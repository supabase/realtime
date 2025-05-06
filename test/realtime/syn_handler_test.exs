defmodule Realtime.SynHandlerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Realtime.SynHandler

  @mod SynHandler
  @name "test"
  @topic "syn_handler"

  describe "on_process_unregistered/5" do
    setup do
      RealtimeWeb.Endpoint.subscribe("#{@topic}:#{@name}")
    end

    test "it handles :syn_conflict_resolution reason" do
      reason = :syn_conflict_resolution

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}
    end

    test "it handles other reasons" do
      reason = :other_reason

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      refute log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}, 500
    end
  end

  describe "resolve_registry_conflict/4" do
    setup do
      :syn.add_node_to_scopes([Realtime.SynHandlerTest])
      :ok
    end

    defmodule TestGen do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: name(opts))
      def init(_), do: {:ok, %{}}
      defp name(opts), do: {:via, :syn, {Realtime.SynHandlerTest, opts[:id]}}
    end

    test "handles processes without region in their state and outputs the the oldest clock to keep" do
      pid = start_supervised!({TestGen, id: Generators.random_string()})

      assert pid ==
               SynHandler.resolve_registry_conflict(
                 __MODULE__,
                 Generators.random_string(),
                 {pid, %{}, System.monotonic_time()},
                 {self(), %{}, System.monotonic_time()}
               )
    end

    test "handles processes with region in their state and outputs the oldest clock to keep" do
      pid = start_supervised!({TestGen, id: Generators.random_string()})

      assert pid ==
               SynHandler.resolve_registry_conflict(
                 __MODULE__,
                 Generators.random_string(),
                 {pid, %{region: "us-east-1"}, System.monotonic_time()},
                 {self(), %{region: "us-east-1"}, System.monotonic_time()}
               )
    end
  end
end
