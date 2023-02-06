defmodule Realtime.Latency do
  @moduledoc """
    Measures the latency of the cluster from each node and broadcasts it over PubSub.
  """

  use GenServer

  require Logger

  alias Realtime.Helpers

  defmodule Payload do
    @moduledoc false

    defstruct [
      :from_node,
      :from_region,
      :node,
      :region,
      :latency,
      :response,
      :timestamp
    ]

    @type t :: %__MODULE__{
            node: atom(),
            region: String.t() | nil,
            from_node: atom(),
            from_region: String.t(),
            latency: integer(),
            response: {:ok, :pong} | {:badrpc, any()},
            timestamp: DateTime
          }
  end

  @every 5_000
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    ping_after()

    {:ok, []}
  end

  def handle_info(:ping, state) do
    ping()
    ping_after()

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_cast({:ping, pong_timeout, timer_timeout, yield_timeout}, state) do
    # For testing
    ping(pong_timeout, timer_timeout, yield_timeout)

    {:noreply, state}
  end

  @doc """
  Pings all the nodes in the cluster one after another and returns with their responses.
  There is a timeout for a single node rpc, and a timeout to yield_many which should really
  never get hit because these pings happen async under the Realtime.TaskSupervisor.

  ## Examples

  Emulate a healthy remote node:

      iex> [{%Task{}, {:ok, %{response: {:ok, {:pong, "iad"}}}}}] = Realtime.Latency.ping()

  Emulate a slow but healthy remote node:

      iex> [{%Task{}, {:ok, %{response: {:ok, {:pong, "iad"}}}}}] = Realtime.Latency.ping(5_000, 10_000, 30_000)

  Emulate an unhealthy remote node:

      iex> [{%Task{}, {:ok, %{response: {:badrpc, :timeout}}}}] = Realtime.Latency.ping(5_000, 1_000)

  No response from our Task for a remote node at all:

      iex> [{%Task{}, nil}] = Realtime.Latency.ping(10_000, 5_000, 2_000)

  """

  @spec ping :: [{%Task{}, tuple() | nil}]
  def ping(pong_timeout \\ 0, timer_timeout \\ 5_000, yield_timeout \\ 5_000) do
    tasks =
      for n <- [Node.self() | Node.list()] do
        Task.Supervisor.async(Realtime.TaskSupervisor, fn ->
          {latency, response} =
            :timer.tc(fn -> :rpc.call(n, __MODULE__, :pong, [pong_timeout], timer_timeout) end)

          latency_ms = latency / 1_000
          fly_region = Application.get_env(:realtime, :fly_region, "iad")
          short_name = Helpers.short_node_id_from_name(n)
          from_node = Helpers.short_node_id_from_name(Node.self())

          case response do
            {:badrpc, reason} ->
              Logger.error(
                "Network error: can't connect to node #{short_name} from #{fly_region} - #{inspect(reason)}"
              )

              payload = %Payload{
                from_node: from_node,
                from_region: fly_region,
                node: short_name,
                region: nil,
                latency: latency_ms,
                response: response,
                timestamp: DateTime.utc_now()
              }

              RealtimeWeb.Endpoint.broadcast("admin:cluster", "pong", payload)

              payload

            {:ok, {:pong, remote_region}} ->
              if latency_ms > 1_000,
                do:
                  Logger.warn(
                    "Network warning: latency to #{remote_region} (#{short_name}) from #{fly_region} (#{from_node}) is #{latency_ms} ms"
                  )

              payload = %Payload{
                from_node: from_node,
                from_region: fly_region,
                node: short_name,
                region: remote_region,
                latency: latency_ms,
                response: response,
                timestamp: DateTime.utc_now()
              }

              RealtimeWeb.Endpoint.broadcast("admin:cluster", "pong", payload)

              payload
          end
        end)
      end
      |> Task.yield_many(yield_timeout)

    for {task, result} <- tasks do
      unless result, do: Task.shutdown(task, :brutal_kill)
    end

    tasks
  end

  @doc """
  A noop function to call from a remote server.
  """

  @spec pong :: {:ok, {:pong, String.t()}}
  def pong() do
    region = Application.get_env(:realtime, :fly_region, "iad")
    {:ok, {:pong, region}}
  end

  @spec pong(:infinity | non_neg_integer) :: {:ok, {:pong, String.t()}}
  def pong(latency) when is_integer(latency) do
    Process.sleep(latency)
    pong()
  end

  defp ping_after() do
    Process.send_after(self(), :ping, @every)
  end
end
