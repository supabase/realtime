defmodule Realtime.Adapters.ConnRetry do
  use GenServer

  alias Retry.DelayStreams

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def get_retry_delay() do
    GenServer.call(__MODULE__, :retry_delay)
  end

  def reset_retry_delay() do
    GenServer.call(__MODULE__, :reset_delay)
  end

  @impl true
  def init(config) do
    config =
      config
      |> Keyword.update!(:conn_retry_initial_delay, &String.to_integer(&1))
      |> Keyword.update!(:conn_retry_maximum_delay, &String.to_integer(&1))
      |> Keyword.update!(:conn_retry_jitter, &(String.to_integer(&1) / 100))

    {:ok, %{config: config, delays: [0]}}
  end

  @impl true
  def handle_call(:retry_delay, _from, %{delays: [delay | delays]} = state) do
    {:reply, delay, %{state | delays: delays}}
  end

  @impl true
  def handle_call(:retry_delay, _from, %{config: config, delays: []} = state) do
    initial_delay = Keyword.get(config, :conn_retry_initial_delay)
    maximum_delay = Keyword.get(config, :conn_retry_maximum_delay)
    jitter = Keyword.get(config, :conn_retry_jitter)

    [delay | delays] =
      DelayStreams.exponential_backoff(initial_delay)
      |> DelayStreams.randomize(jitter)
      |> DelayStreams.expiry(maximum_delay)
      |> Enum.to_list()

    {:reply, delay, %{state | delays: delays}}
  end

  @impl true
  def handle_call(:reset_delay, _from, state) do
    {:reply, :ok, %{state | delays: [0]}}
  end
end
