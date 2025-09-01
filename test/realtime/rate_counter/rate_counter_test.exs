defmodule Realtime.RateCounterTest do
  use Realtime.DataCase, async: true

  require Logger

  alias Realtime.RateCounter
  alias Realtime.RateCounter.Args
  alias Realtime.GenCounter

  import ExUnit.CaptureLog

  describe "new/2" do
    test "starts a new rate counter without telemetry" do
      id = {:domain, :metric, Ecto.UUID.generate()}
      args = %Args{id: id, opts: []}
      assert {:ok, pid} = RateCounter.new(args)

      assert %Realtime.RateCounter{
               id: ^id,
               avg: +0.0,
               bucket: _,
               max_bucket_len: 60,
               tick: 1000,
               tick_ref: _,
               idle_shutdown: 900_000,
               idle_shutdown_ref: _,
               telemetry: %{emit: false},
               limit: %{log: false}
             } = :sys.get_state(pid)
    end

    test "starts a new rate counter with telemetry" do
      :telemetry.detach(__MODULE__)

      :telemetry.attach(
        __MODULE__,
        [:realtime, :rate_counter, :custom, :new_event],
        &__MODULE__.handle_telemetry/4,
        pid: self()
      )

      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 10,
          telemetry: %{
            event_name: [:custom, :new_event],
            measurements: %{limit: 123},
            metadata: %{tenant: "abc"}
          }
        ]
      }

      assert {:ok, pid} = RateCounter.new(args)

      assert %Realtime.RateCounter{
               id: ^id,
               avg: +0.0,
               bucket: _,
               max_bucket_len: 60,
               tick: 10,
               tick_ref: _,
               idle_shutdown: 900_000,
               idle_shutdown_ref: _,
               telemetry: %{
                 emit: true,
                 event_name: [:realtime, :rate_counter, :custom, :new_event],
                 measurements: %{sum: 0, limit: 123},
                 metadata: %{id: ^id, tenant: "abc"}
               }
             } = :sys.get_state(pid)

      GenCounter.add(args.id, 10)

      assert_receive {
        [:realtime, :rate_counter, :custom, :new_event],
        %{sum: 10, limit: 123},
        %{id: ^id, tenant: "abc"}
      }
    end

    test "raise error when limit is specified without measurement" do
      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 100,
          max_bucket_len: 10,
          limit: [
            value: 10,
            log_fn: fn ->
              Logger.error("ErrorMessage: Reason", external_id: "tenant123", project: "tenant123")
            end
          ]
        ]
      }

      assert {:error, {%KeyError{key: :measurement, term: _}, _}} = RateCounter.new(args)
    end

    test "raise error when limit is specified without value" do
      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 100,
          max_bucket_len: 10,
          limit: [
            measurement: :avg,
            log_fn: fn ->
              Logger.error("ErrorMessage: Reason", external_id: "tenant123", project: "tenant123")
            end
          ]
        ]
      }

      assert {:error, {%KeyError{key: :value, term: _}, _}} = RateCounter.new(args)
    end

    test "raise error when limit is specified without log_fn" do
      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 100,
          max_bucket_len: 10,
          limit: [
            measurement: :avg,
            value: 100
          ]
        ]
      }

      assert {:error, {%KeyError{key: :log_fn, term: _}, _}} = RateCounter.new(args)
    end

    test "starts a new rate counter with avg limit to log" do
      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 100,
          max_bucket_len: 10,
          limit: [
            value: 10,
            measurement: :avg,
            log_fn: fn ->
              Logger.error("ErrorMessage: Reason", external_id: "tenant123", project: "tenant123")
            end
          ]
        ]
      }

      assert {:ok, pid} = RateCounter.new(args)

      assert %RateCounter{
               id: ^id,
               avg: +0.0,
               bucket: _,
               max_bucket_len: 10,
               telemetry: %{emit: false},
               limit: %{
                 log: true,
                 value: 10,
                 triggered: false
               }
             } = :sys.get_state(pid)

      log =
        capture_log(fn ->
          GenCounter.add(args.id, 50)
          Process.sleep(300)
        end)

      assert {:ok, %RateCounter{limit: %{triggered: true}}} = RateCounter.get(args)
      assert log =~ "project=tenant123 external_id=tenant123 [error] ErrorMessage: Reason"

      # Only one log message should be emitted
      # Splitting by the error message returns the error message and the rest of the log only
      assert length(String.split(log, "ErrorMessage: Reason")) == 2

      Process.sleep(300)

      assert {:ok, %RateCounter{limit: %{triggered: false}}} = RateCounter.get(args)
    end

    test "starts a new rate counter with sum limit to log" do
      id = {:domain, :metric, Ecto.UUID.generate()}

      args = %Args{
        id: id,
        opts: [
          tick: 100,
          max_bucket_len: 3,
          limit: [
            value: 49,
            measurement: :sum,
            log_fn: fn ->
              Logger.error("ErrorMessage: Reason", external_id: "tenant123", project: "tenant123")
            end
          ]
        ]
      }

      assert {:ok, pid} = RateCounter.new(args)

      assert %RateCounter{
               id: ^id,
               avg: +0.0,
               sum: 0,
               bucket: _,
               max_bucket_len: 3,
               telemetry: %{emit: false},
               limit: %{
                 log: true,
                 value: 49,
                 measurement: :sum,
                 triggered: false
               }
             } = :sys.get_state(pid)

      log =
        capture_log(fn ->
          GenCounter.add(args.id, 100)
          Process.sleep(100)
        end)

      assert {:ok, %RateCounter{sum: sum, limit: %{triggered: true}}} = RateCounter.get(args)
      assert sum > 49
      assert log =~ "project=tenant123 external_id=tenant123 [error] ErrorMessage: Reason"

      # Only one log message should be emitted
      # Splitting by the error message returns the error message and the rest of the log only
      assert length(String.split(log, "ErrorMessage: Reason")) == 2

      Process.sleep(400)

      assert {:ok, %RateCounter{sum: 0, limit: %{triggered: false}}} = RateCounter.get(args)
    end

    test "reset counter if GenCounter already had something" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}
      GenCounter.add(args.id, 100)
      assert {:ok, _} = RateCounter.new(args)
      assert GenCounter.get(args.id) == 0
    end

    test "rate counters are unique for an Erlang term" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}
      {:ok, pid} = RateCounter.new(args)

      assert {:error, {:already_started, ^pid}} = RateCounter.new(args)
    end

    test "rate counters shut themselves down when no activity occurs on the GenCounter" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}
      {:ok, pid} = RateCounter.new(args, idle_shutdown: 5)

      Process.monitor(pid)
      assert_receive {:DOWN, _ref, :process, ^pid, :normal}, 25
      # Cache has not expired yet
      assert {:ok, %RateCounter{}} = Cachex.get(RateCounter, args.id)
      Process.sleep(2000)
      assert {:ok, nil} = Cachex.get(RateCounter, args.id)

      # Ok new RateCounter automatically started now
      assert {:ok, %RateCounter{}} = RateCounter.get(args)

      [{new_pid, _}] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, args.id})
      assert new_pid != pid
    end

    test "rate counters reset GenCounter to zero after one tick and average the bucket" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}
      {:ok, _pid} = RateCounter.new(args, tick: 5)
      assert GenCounter.add(args.id) == 1
      Process.sleep(10)

      assert {:ok,
              %RateCounter{
                avg: avg,
                bucket: bucket,
                id: _id,
                idle_shutdown: _,
                idle_shutdown_ref: _ref,
                max_bucket_len: 60,
                tick: 5,
                tick_ref: _ref2
              }} = RateCounter.get(args)

      assert 1 in bucket
      assert avg > 0.0

      assert GenCounter.get(args.id) == 0
    end
  end

  describe "get/1" do
    test "gets the state of a rate counter" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}
      {:ok, _} = RateCounter.new(args)

      assert {:ok, %RateCounter{}} = RateCounter.get(args)
    end

    test "creates counter if not started yet" do
      args = %Args{id: {:domain, :metric, Ecto.UUID.generate()}}

      assert {:ok, %RateCounter{}} = RateCounter.get(args)
    end
  end

  describe "stop/1" do
    test "stops rate counters for a given entity" do
      entity_id = Ecto.UUID.generate()
      fake_terms = Enum.map(1..10, fn _ -> {:domain, :"metric_#{random_string()}", Ecto.UUID.generate()} end)
      terms = Enum.map(1..10, fn _ -> {:domain, :"metric_#{random_string()}", entity_id} end)

      for term <- terms do
        args = %Args{id: term}
        {:ok, _} = RateCounter.new(args)
        assert {:ok, %RateCounter{}} = RateCounter.get(args)
      end

      for term <- fake_terms do
        args = %Args{id: term}
        {:ok, _} = RateCounter.new(args)
        assert {:ok, %RateCounter{}} = RateCounter.get(args)
      end

      assert :ok = RateCounter.stop(entity_id)
      # Wait for processes to shut down and Registry to update
      Process.sleep(100)

      for term <- terms do
        assert [] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, term})
      end

      for term <- fake_terms do
        assert [{_pid, _value}] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, term})
      end
    end
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {event, measures, metadata})
end
