defmodule RealtimeWeb.InspectorLive.ConnComponent do
  use RealtimeWeb, :live_component

  defmodule Connection do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:log_level, :string)
      field(:token, :string)
      field(:path, :string)
      field(:project, :string)
      field(:channel, :string)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:log_level, :token, :path, :project, :channel])
      |> validate_required([:channel])
    end
  end

  @impl true
  def mount(socket) do
    changeset = Connection.changeset(%Connection{})

    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> assign(changeset: changeset)

    {:ok, socket}
  end

  @impl true
  def update(_assigns, socket) do
    changeset = Connection.changeset(%Connection{})

    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> assign(changeset: changeset)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["connection", "path"], "connection" => conn},
        socket
      ) do
    conn = Map.drop(conn, ["project"])

    changeset = Connection.changeset(%Connection{}, conn)

    socket = socket |> assign(changeset: changeset)
    {:noreply, socket}
  end

  def handle_event(
        "validate",
        %{"_target" => ["connection", "project"], "connection" => %{"project" => project} = conn},
        socket
      ) do
    ws_url = "wss://#{project}.supabase.co/realtime/v1"

    conn = conn |> Map.put("path", ws_url) |> Map.put("project", project)

    changeset = Connection.changeset(%Connection{}, conn)

    socket = socket |> assign(changeset: changeset)
    {:noreply, socket}
  end

  def handle_event("validate", %{"connection" => conn}, socket) do
    changeset = Connection.changeset(%Connection{}, conn)

    socket = socket |> assign(changeset: changeset)
    {:noreply, socket}
  end

  def handle_event("connect", params, socket) do
    socket =
      socket
      |> assign(subscribed_state: "Connecting...")
      |> push_event("connect", params)

    {:noreply, socket}
  end

  def handle_event("disconnect", _params, socket) do
    socket =
      socket
      |> assign(subscribed_state: "Connect")
      |> push_event("disconnect", %{})

    {:noreply, socket}
  end

  def handle_event("local_storage", params, socket) do
    changeset = Connection.changeset(%Connection{}, params)

    {:noreply, assign(socket, changeset: changeset)}
  end

  def handle_event("cancel", params, socket) do
    changeset = Connection.changeset(%Connection{}, params)

    {:noreply, assign(socket, changeset: changeset)}
  end

  def handle_event("subscribed", _params, socket) do
    send(
      self(),
      {:subscribed_successfully,
       %{subscribed_state: "Connected", changeset: socket.assigns.changeset}}
    )

    socket =
      socket
      |> assign(subscribed_state: "Connected")
      |> push_patch(to: Routes.inspector_index_path(socket, :index))

    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Connect - Inspector - Supabase Realtime")
  end
end
