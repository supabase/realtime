defmodule RealtimeWeb.InspectorLive.Index do
  use RealtimeWeb, :live_view

  defmodule Message do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:event, :string)
      field(:payload, :string)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:event, :payload])
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Message.changeset(%Message{event: "test", payload: ~s({"some":"data"})})

    socket =
      socket
      |> assign(changeset: changeset)
      |> assign(subscribed_state: "Connect")
      |> assign(subscribed_to: nil)
      |> assign(:page_title, "Inspector - Supabase Realtime")

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", params, socket) do
    {:noreply, push_event(socket, "send_message", params)}
  end

  @impl true
  def handle_info({:subscribed_successfully, state}, socket) do
    socket =
      socket
      |> assign(subscribed_state: state.subscribed_state)
      |> assign(subscribed_to: state.changeset.changes.path)

    {:noreply, socket}
  end
end
