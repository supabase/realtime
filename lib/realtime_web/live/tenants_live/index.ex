defmodule RealtimeWeb.TenantsLive.Index do
  use RealtimeWeb, :live_view

  alias Realtime.Api
  alias Realtime.Api.Tenant

  defmodule Socket do
    defstruct [:tenants, :filter_changeset, :sort_fields]
  end

  defmodule Filter do
    use Ecto.Schema
    import Ecto.Changeset

    schema "f" do
      field(:sort_by, :string)
      field(:search, :string)
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:sort_by, :search])
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      %Socket{
        tenants: [],
        filter_changeset: Filter.changeset(%Filter{}, %{})
      }
      |> Map.from_struct()

    sort_fields = %Tenant{} |> Map.keys() |> Enum.drop(2)

    socket =
      socket
      |> assign(defaults)
      |> assign(tenants: list_tenants())
      |> assign(sort_fields: sort_fields)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(filter_changeset: Filter.changeset(socket.assigns.filter_changeset, params))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"filter" => filter}, socket) do
    changeset = Filter.changeset(socket.assigns.filter_changeset, filter)

    socket =
      socket
      |> assign(filter_changeset: changeset)
      |> push_patch(
        to: Routes.tenants_index_path(RealtimeWeb.Endpoint, :index, changeset.changes),
        replace: true
      )

    {:noreply, socket}
  end

  def handle_event("filter_submit", %{"filter" => filter}, socket) do
    tenants = list_tenants(order_by: filter["sort_by"])

    socket =
      socket
      |> assign(tenants: tenants)
      |> push_patch(
        to: Routes.tenants_index_path(RealtimeWeb.Endpoint, :index, filter),
        replace: true
      )

    {:noreply, socket}
  end

  defp list_tenants(opts \\ []) when is_list(opts) do
    Api.list_tenants(opts) |> Enum.take(10)
  end
end
