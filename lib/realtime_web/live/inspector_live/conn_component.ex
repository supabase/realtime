defmodule RealtimeWeb.InspectorLive.ConnComponent do
  use RealtimeWeb, :live_component

  defmodule Connection do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:log_level, :string, default: "error")
      field(:token, :string)
      field(:host, :string)
      field(:project, :string)
      field(:channel, :string, default: "room_a")
      field(:schema, :string, default: "public")
      field(:table, :string, default: "*")
      field(:filter, :string)
      field(:bearer, :string)
      field(:enable_broadcast, :boolean, default: true)
      field(:enable_presence, :boolean, default: false)
      field(:enable_db_changes, :boolean, default: false)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [
        :log_level,
        :token,
        :host,
        :project,
        :channel,
        :schema,
        :table,
        :filter,
        :bearer,
        :enable_broadcast,
        :enable_presence,
        :enable_db_changes
      ])
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
      |> assign(url_params: %{})

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["connection", "host"], "connection" => conn},
        socket
      ) do
    conn = Map.drop(conn, ["project"])

    changeset = Connection.changeset(%Connection{}, conn)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, conn),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event(
        "validate",
        %{"_target" => ["connection", "project"], "connection" => %{"project" => project} = conn},
        socket
      ) do
    host = "https://#{project}.supabase.co"

    conn = conn |> Map.put("host", host) |> Map.put("project", project)

    changeset = Connection.changeset(%Connection{}, conn)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, conn),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("validate", %{"connection" => conn}, socket) do
    changeset = Connection.changeset(%Connection{}, conn)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, conn),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("connect", %{"connection" => conn} = params, socket) do
    send_share_url(conn)

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

  def handle_event("clear_local_storage", _params, socket) do
    socket =
      socket
      |> push_event("clear_local_storage", %{})
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("local_storage", _params, %{assigns: %{url_params: url_params}} = socket)
      when url_params != %{} do
    {:noreply, socket}
  end

  def handle_event(
        "local_storage",
        %{
          "channel" => nil,
          "host" => nil,
          "schema" => nil,
          "table" => nil,
          "token" => nil,
          "filter" => nil,
          "bearer" => nil,
          "enable_presence" => nil,
          "enable_db_changes" => nil
        },
        socket
      ) do
    {:noreply, socket}
  end

  def handle_event("local_storage", %{"log_level" => nil} = params, socket) do
    params = Map.drop(params, ["log_level"])
    changeset = Connection.changeset(%Connection{}, params)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, params),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("local_storage", params, socket) do
    changeset = Connection.changeset(%Connection{}, params)

    socket =
      socket
      |> assign(changeset: changeset)
      |> push_patch(
        to: Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, params),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("cancel", params, socket) do
    changeset = Connection.changeset(%Connection{}, params)

    {:noreply, assign(socket, changeset: changeset)}
  end

  defp send_share_url(conn) do
    conn = Map.drop(conn, ["token"])
    url = Routes.inspector_index_path(RealtimeWeb.Endpoint, :new, conn)
    send(self(), {:share_url, url})
  end
end
