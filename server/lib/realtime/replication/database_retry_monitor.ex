defmodule Realtime.DatabaseRetryMonitor do
  use GenServer

  alias Retry.DelayStreams

  @initial_delay 500           # Half a second
  @maximum_delay 5 * 60 * 1000 # Five minutes

  def start_link(arg) do
    name = Keyword.get(arg, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  def get_delay(name \\ __MODULE__) do
    GenServer.call(name, :delay)
  end

  def reset_delay(name \\ __MODULE__) do
    GenServer.call(name, :reset)
  end

  @impl true
  def init(_) do
    {:ok, []}
  end

  @impl true
  def handle_call(:delay, _, [delay | delays]) do
    {:reply, delay, delays}
  end

  @doc """

  Initial delay is 0 milliseconds for immediate connect attempt.

  Future delays are generated and saved to state.

    * Begin with @initial_delay and increase by a factor of 2
    * Each is randomly adjusted within 10% of its value
    * Capped at @maximum_delay

    Example

      [486, 918, 1931, 4067, 7673, 15699, 31783, 64566, 125929, 251911, 300000]

  """
  @impl true
  def handle_call(:delay, _, []) do
    delays =
      DelayStreams.exponential_backoff(@initial_delay)
      |> DelayStreams.randomize()
      |> DelayStreams.expiry(@maximum_delay)
      |> Enum.to_list()

    {:reply, 0, delays}
  end

  @impl true
  def handle_call(:reset, _, _) do
    {:reply, :ok, []}
  end
end
