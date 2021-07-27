defmodule Multiplayer.PresenceNotify do
  use GenServer
  require Logger

  defmodule(State,
    do:
      defstruct(
        mq: []
      )
  )

  def track_me(pid, socket) do
    send(__MODULE__, {:track, pid, socket})
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_info({:track, pid, socket}, %{mq: mq} = state) do
    send(self(), :check_mq)
    {:noreply, %{state | mq: mq ++ [{pid, socket}]}}
  end

  def handle_info(:check_mq, %{mq: []} = state) do
    {:noreply, state, :hibernate}
  end

  def handle_info(:check_mq, %{mq: [{pid, socket} | mq]} = state) do
    {:ok, _} = MultiplayerWeb.Presence.track(
      socket,
      socket.assigns.params.user_id,
      socket.assigns.params
    )
    send(pid, :presence_state)
    send(self(), :check_mq)
    {:noreply, %{state | mq: mq}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

end
