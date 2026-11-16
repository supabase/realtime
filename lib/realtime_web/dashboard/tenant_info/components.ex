defmodule RealtimeWeb.Dashboard.TenantInfo.Components do
  @moduledoc """
  Function components that the sections of the Tenant Info dashboard page (`RealtimeWeb.Dashboard.TenantInfo`)
  share. They render the Bootstrap markup of LiveDashboard.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc "A card with a title."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :flush, :boolean, default: true, doc: "no padding around the body, for a table that fills the card"
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <div id={@id} class="card mb-4">
      <div class="card-header"><strong>{@title}</strong></div>
      <div class={["card-body", @flush && "p-0"]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "A table of `{key, value}` rows, without a header."
  attr :rows, :list, required: true
  attr :empty, :string, default: nil, doc: "the text of the only row when there are no rows"

  def kv_table(assigns) do
    ~H"""
    <table class="table table-hover mb-0">
      <tbody>
        <tr :if={@empty && @rows == []}><td class="text-muted">{@empty}</td></tr>
        <tr :for={{key, value} <- @rows}>
          <td>{key}</td>
          <td>{value}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  A table with a header and one column per `:col` slot. Each slot gets the row with `:let`. A `code`
  column shows monospace text that can wrap anywhere, for SQL, ACLs and function signatures.
  """
  attr :id, :string, default: nil
  attr :rows, :list, required: true
  attr :class, :string, default: "table table-sm mb-0"
  attr :empty, :string, default: nil, doc: "the text of the only row when there are no rows"

  slot :col, required: true do
    attr :label, :string, required: true
    attr :code, :boolean
  end

  def table(assigns) do
    # The whitespace around each cell's content keeps the text of a row readable as words.
    ~H"""
    <table id={@id} class={@class}>
      <thead>
        <tr><th :for={col <- @col}>{col.label}</th></tr>
      </thead>
      <tbody>
        <tr :if={@empty && @rows == []}><td colspan={length(@col)} class="text-muted">{@empty}</td></tr>
        <tr :for={row <- @rows}>
          <td :for={col <- @col} {cell_attrs(col)}>
            {render_slot(col, row)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp cell_attrs(%{code: true}), do: [class: "text-monospace", style: "overflow-wrap: anywhere;"]
  defp cell_attrs(_col), do: []

  @doc """
  A section that starts collapsed and reads its content the first time it opens.

  The summary sends `event`, with `section` as `phx-value-section`, on every click, closing included.
  The page must read only on the first one, so the section keeps what it showed until the next lookup.
  The patches of LiveView leave `open` alone, so the section stays open while its rows come in and
  through auto-refresh.

  `state` is `nil` until the read returns, then `{:ok, value}` or `{:error, message}`. The inner block
  gets `value` with `:let`.
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :section, :string, default: nil
  attr :title, :string, required: true
  attr :state, :any, required: true
  attr :count, :any, default: nil, doc: "a function of the value that gives the count after the title"
  attr :rest, :global, doc: "more attributes of the details tag, such as `class`"
  slot :warning, doc: "red text after the title"
  slot :inner_block, required: true

  def lazy_section(assigns) do
    ~H"""
    <details id={@id} phx-mounted={JS.ignore_attributes("open")} {@rest}>
      <summary phx-click={@event} phx-value-section={@section}>
        <h6 class="d-inline">{title(@title, @state, @count)}</h6>
        <span :for={warning <- @warning} class="text-danger">· {render_slot(warning)}</span>
      </summary>
      <%= case @state do %>
        <% {:ok, value} -> %>{render_slot(@inner_block, value)}
        <% nil -> %><p class="text-muted small mt-2 mb-0">Loading...</p>
        <% {:error, message} -> %><p class="text-danger mt-2 mb-0">{message}</p>
      <% end %>
    </details>
    """
  end

  defp title(title, {:ok, value}, count) when is_function(count, 1), do: "#{title} (#{count.(value)})"
  defp title(title, _state, _count), do: title

  @doc "Whether a tenant process is up, and on which node."
  attr :process, :map, required: true, doc: "`%{up: boolean(), node: node() | nil}`"

  def status(assigns) do
    ~H"""
    <%= if @process.up do %>
      <span class="text-success">up</span> <span class="text-monospace">({@process.node})</span>
    <% else %>
      <span class="text-muted">not connected</span>
    <% end %>
    """
  end

  @doc "A yes or no value. It is red when it is not the `expected` one."
  attr :value, :boolean, required: true
  attr :expected, :boolean, required: true
  attr :yes, :string, default: "yes"
  attr :no, :string, default: "no"

  def flag(assigns) do
    ~H"""
    <span class={@value != @expected && "text-danger"}>{if @value, do: @yes, else: @no}</span>
    """
  end
end
