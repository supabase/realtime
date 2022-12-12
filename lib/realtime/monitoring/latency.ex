defmodule Realtime.Latency do
  @moduledoc """
    Measures the latency of the cluster from each node and broadcasts it over PubSub.
  """

  use GenServer

  require Logger

  defmodule Payload do
    @moduledoc false

    defstruct [
      :from_node,
      :node,
      :latency,
      :response,
      :timestamp
    ]

    @type t :: %__MODULE__{
            node: atom(),
            from_node: atom(),
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

  def handle_info({_ref, _payload}, state) do
    Logger.warn("Remote node ping task replied after `yield_many` timeout.")
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

      iex> [{%Task{}, {:ok, %{response: {:ok, :pong}}}}] = Realtime.Latency.ping()

  Emulate a slow but healthy remote node:

      iex> [{%Task{}, {:ok, %{response: {:ok, :pong}}}}] = Realtime.Latency.ping(5_000, 10_000, 30_000)

  Emulate an unhealthy remote node:

      iex> [{%Task{}, {:ok, %{response: {:badrpc, :timeout}}}}] = Realtime.Latency.ping(5_000, 1_000)

  No response from our Task for a remote node at all:

      iex> [{%Task{}, nil}] = Realtime.Latency.ping(10_000, 5_000, 2_000)

  """

  @spec ping :: [{%Task{}, tuple() | nil}]
  def ping(pong_timeout \\ 0, timer_timeout \\ 5_000, yield_timeout \\ 30_000) do
    for n <- [Node.self() | Node.list()] do
      Task.Supervisor.async(Realtime.TaskSupervisor, fn ->
        {latency, {status, _respose} = reply} =
          :timer.tc(fn -> :rpc.call(n, __MODULE__, :pong, [pong_timeout], timer_timeout) end)

        latency_ms = latency / 1_000

        fly_region = Application.get_env(:realtime, :fly_region)

        cond do
          status == :badrpc ->
            Logger.error("Network error: can't connect to node #{n} from #{fly_region}")

          latency_ms > 1_000 ->
            Logger.warn(
              "Network warning: latency is > #{latency_ms} ms to node #{n} from #{fly_region}"
            )

          true ->
            :noop
        end

        payload = %Payload{
          from_node: Node.self(),
          node: n,
          latency: latency_ms,
          response: reply,
          timestamp: DateTime.utc_now()
        }

        RealtimeWeb.Endpoint.broadcast("admin:cluster", "pong", payload)

        payload
      end)
    end
    |> Task.yield_many(yield_timeout)
  end

  @doc """
  A noop function to call from a remote server.
  """

  @spec pong :: {:ok, :pong}
  def pong() do
    {:ok, :pong}
  end

  @spec pong(:infinity | non_neg_integer) :: {:ok, :pong}
  def pong(latency) when is_integer(latency) do
    Process.sleep(latency)
    {:ok, :pong}
  end

  defp ping_after() do
    Process.send_after(self(), :ping, @every)
  end
end
