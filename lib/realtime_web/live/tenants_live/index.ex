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
      field(:order_by, :string, default: "inserted_at")
      field(:search, :string, default: nil)
      field(:limit, :integer, default: 10)
      field(:order, :string, default: "desc")
    end

    def changeset(form, params \\ %{}) do
      form
      |> cast(params, [:order_by, :search, :limit, :order])
    end

    def apply_changes_form(changeset) do
      apply_changes(changeset)
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
      |> assign(tenants: list_tenants(%Filter{}))
      |> assign(sort_fields: sort_fields)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    changeset = Filter.changeset(socket.assigns.filter_changeset, params)
    form = Filter.apply_changes_form(changeset)

    socket =
      socket
      |> assign(filter_changeset: changeset)
      |> assign(
        tenants:
          Api.list_tenants(
            search: form.search,
            order_by: form.order_by,
            limit: form.limit,
            order: form.order
          )
      )

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

  defp list_tenants(%Filter{} = filter) do
    filter |> Map.from_struct() |> Enum.into([]) |> Api.list_tenants()
  end
end
