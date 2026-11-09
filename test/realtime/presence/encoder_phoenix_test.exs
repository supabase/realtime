defmodule Realtime.Presence.EncoderPhoenixTest do
  # Runs the same steps through Phoenix Presence and through Rollcall with the encoder and the
  # Realtime transport. `assert_compatible/1` then compares the `presence_diff` messages that each
  # side broadcast on PubSub, one by one, and the presence state of each side.
  #
  # A client decodes JSON, so the comparison decodes both sides from JSON. The refs differ between
  # the two sides, so the comparison replaces each ref by the number of the step that made it. The
  # order of the metas under one key is not defined, so the comparison sorts them.
  use ExUnit.Case, async: false

  alias Phoenix.Socket.Broadcast
  alias Realtime.Presence.Encoder
  alias Realtime.Presence.RollcallTransport
  alias RealtimeWeb.Presence
  alias Realtime.Presence.Metrics

  @timeout 1_000

  setup do
    id = System.unique_integer([:positive])
    name = :"encoder_phoenix_#{id}"

    start_supervised!({Rollcall, name: name, transport: {RollcallTransport, []}, heartbeat_period_in_ms: :manual})

    phoenix_topic = "compare-phoenix:#{id}"
    rollcall_topic = "compare-rollcall:#{id}"
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, phoenix_topic)
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, rollcall_topic)

    scenario = %{
      rollcall: name,
      scope: "scope-#{id}",
      phoenix_topic: phoenix_topic,
      rollcall_topic: rollcall_topic,
      clients: Map.new([:phone, :laptop], &{&1, start_client()}),
      tracked: MapSet.new(),
      # The refs that each side returned, in the order of the steps that made them.
      refs: [],
      # The number of diffs that each side must have broadcast.
      diffs: 0
    }

    {:ok, scenario: scenario}
  end

  describe "the diffs and the state are the same for" do
    test "a track", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> assert_compatible()
    end

    test "an update", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> track(:phone, "alice", %{"status" => "away"})
      |> assert_compatible()
    end

    test "an update of an update", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> track(:phone, "alice", %{"status" => "away"})
      |> track(:phone, "alice", %{"status" => "busy"})
      |> assert_compatible()
    end

    test "an update with the same meta", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> track(:phone, "alice", %{"status" => "online"})
      |> assert_compatible()
    end

    test "an untrack", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> untrack(:phone, "alice")
      |> assert_compatible()
    end

    test "a track that follows an untrack", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"status" => "online"})
      |> untrack(:phone, "alice")
      |> track(:phone, "alice", %{"status" => "away"})
      |> assert_compatible()
    end

    test "an untrack of an entry that does not exist", %{scenario: scenario} do
      scenario
      |> untrack(:phone, "alice")
      |> track(:phone, "alice", %{"status" => "online"})
      |> untrack(:phone, "bob")
      |> track(:phone, "alice", %{"status" => "away"})
      |> assert_compatible()
    end

    test "two clients that track one key", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"device" => "phone"})
      |> track(:laptop, "alice", %{"device" => "laptop"})
      |> untrack(:phone, "alice")
      |> assert_compatible()
    end

    test "an update of one of two entries with one key", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"device" => "phone"})
      |> track(:laptop, "alice", %{"device" => "laptop"})
      |> track(:phone, "alice", %{"device" => "phone", "status" => "away"})
      |> assert_compatible()
    end

    test "an update while another client tracks and untracks the key", %{scenario: scenario} do
      scenario
      |> track(:phone, "alice", %{"device" => "phone"})
      |> track(:laptop, "alice", %{"device" => "laptop"})
      |> track(:phone, "alice", %{"device" => "phone", "status" => "away"})
      |> untrack(:laptop, "alice")
      |> track(:phone, "alice", %{"device" => "phone", "status" => "busy"})
      |> assert_compatible()
    end

    test "a meta that has an envelope", %{scenario: scenario} do
      envelope = %{ts: 1, node: "n1"}

      scenario
      |> track(:phone, "alice", %{"status" => "online", _rt: envelope})
      |> track(:phone, "alice", %{"status" => "away", _rt: envelope})
      |> assert_compatible()
    end
  end

  # Steps. Each step runs on both sides and records what it did.

  # Tracks the entry, or updates it when `client` has the entry already.
  defp track(scenario, client, key, meta) do
    pid = Map.fetch!(scenario.clients, client)

    {:ok, phoenix_ref} =
      case Presence.track(pid, scenario.phoenix_topic, key, meta) do
        {:error, {:already_tracked, _pid, _topic, _key}} -> Presence.update(pid, scenario.phoenix_topic, key, meta)
        result -> result
      end

    {:ok, rollcall_ref} = Rollcall.track(scenario.rollcall, pid, scenario.scope, scenario.rollcall_topic, key, meta)

    %{
      scenario
      | tracked: MapSet.put(scenario.tracked, {client, key}),
        refs: scenario.refs ++ [{phoenix_ref, rollcall_ref}],
        diffs: scenario.diffs + 1
    }
  end

  # Untracks the entry. An entry that does not exist changes nothing, so no diff is expected.
  defp untrack(scenario, client, key) do
    pid = Map.fetch!(scenario.clients, client)
    existed? = MapSet.member?(scenario.tracked, {client, key})

    :ok = Presence.untrack(pid, scenario.phoenix_topic, key)
    :ok = Rollcall.untrack(scenario.rollcall, pid, scenario.scope, scenario.rollcall_topic, key)

    %{
      scenario
      | tracked: MapSet.delete(scenario.tracked, {client, key}),
        diffs: if(existed?, do: scenario.diffs + 1, else: scenario.diffs)
    }
  end

  # Receives the diffs of each side in order, and compares them one by one. Then compares the state.
  # Each side sends its diffs in order, so a diff that a step did not expect shows as a mismatch.
  defp assert_compatible(scenario) do
    {phoenix_numbers, rollcall_numbers} = ref_numbers(scenario)

    for number <- 1..scenario.diffs//1 do
      phoenix_diff = scenario.phoenix_topic |> receive_diff() |> normalize_diff(phoenix_numbers)
      rollcall_diff = scenario.rollcall_topic |> receive_diff() |> normalize_diff(rollcall_numbers)

      assert phoenix_diff == rollcall_diff, "diff #{number} differs"
    end

    phoenix_state = scenario.phoenix_topic |> Presence.list() |> Metrics.strip_state()
    rollcall_state = scenario |> rollcall_state() |> Metrics.strip_state()

    assert normalize_state(phoenix_state, phoenix_numbers) == normalize_state(rollcall_state, rollcall_numbers),
           "the states differ"
  end

  # Clients and messages.

  defp start_client do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp receive_diff(topic) do
    receive do
      %Broadcast{topic: ^topic, event: "presence_diff", payload: payload} -> payload
    after
      @timeout -> flunk("No presence_diff on #{topic} within #{@timeout} ms")
    end
  end

  defp rollcall_state(scenario) do
    scenario.rollcall
    |> Rollcall.state(scenario.scope, scenario.rollcall_topic)
    |> Encoder.state()
  end

  # What a client decodes: JSON, with each ref replaced by the number of its step.

  # Returns a map from ref to step number for each side.
  defp ref_numbers(%{refs: refs}) do
    numbered = Enum.with_index(refs, 1)

    {Map.new(numbered, fn {{phoenix_ref, _rollcall_ref}, number} -> {phoenix_ref, number} end),
     Map.new(numbered, fn {{_phoenix_ref, rollcall_ref}, number} -> {rollcall_ref, number} end)}
  end

  defp normalize_diff(%{joins: joins, leaves: leaves}, numbers) do
    %{joins: normalize_state(joins, numbers), leaves: normalize_state(leaves, numbers)}
  end

  defp normalize_state(state, numbers) do
    state
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.new(fn {key, %{"metas" => metas}} ->
      metas = metas |> Enum.map(&normalize_meta(&1, numbers)) |> Enum.sort_by(& &1["phx_ref"])
      {key, metas}
    end)
  end

  defp normalize_meta(meta, numbers) do
    meta = Map.update!(meta, "phx_ref", &Map.fetch!(numbers, &1))

    case meta do
      %{"phx_ref_prev" => prev} -> %{meta | "phx_ref_prev" => Map.fetch!(numbers, prev)}
      meta -> meta
    end
  end
end
