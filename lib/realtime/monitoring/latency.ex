defmodule Realtime.Latency do
  @moduledoc """
    Measures the latency of the cluster from each node and broadcasts it over PubSub.
  """

  use GenServer

  require Logger

  defmodule Payload do
    @moduledoc false

    @defstruct [
      :from_node,
      :node,
      :latency,
      :response
    ]

    #    @type t :: %__MODULE__{
    #            node: atom(),
    #            latency: integer(),
    #            response: {:ok, :pong} | {:badrpc, any()}
    #          }
  end

  @every 5_000
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(_args) do
    ping_after()

    {:ok, []}
  end

  def hanle_info(:ping, state) do
    # This bullshit is not getting called
    ping()
    ping_after()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    # IO.inspect(msg, label: "BULLSHIT")
    ping()
    ping_after()
    {:noreply, state}
  end

  @doc """
  Pings all the nodes in the cluster one after another and returns with their responses.
  There is a timeout for a single node rpc, and a timeout to yield_many which should really
  never get hit because these pings happen async under the Realtime.TaskSupervisor.
  """

  @spec ping :: [{%Task{}, tuple()}]
  def ping() do
    for n <- Node.list() do
      {latency, {status, _respose} = reply} =
        :timer.tc(fn -> :rpc.call(n, __MODULE__, :pong, [], 5_000) end)

      latency_ms = latency / 1_000

      fly_region = Application.get_env(:realtime, :fly_region)

      if status == :badrpc,
        do: Logger.error("Network error: can't connect to node #{n} from #{fly_region}")

      if latency_ms > 1_000,
        do:
          Logger.warn(
            "Network warning: latency is > #{latency_ms} ms to node #{n} from #{fly_region}"
          )

      payload = %{
        from_node: Node.self(),
        node: n,
        latency: latency_ms,
        response: reply
      }

      RealtimeWeb.Endpoint.broadcast("admin:cluster", "pong", payload)

      payload
    end
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
