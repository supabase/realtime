defmodule RealtimeWeb.Dashboard.TenantInfo.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import RealtimeWeb.Dashboard.TenantInfo.Components

  describe "lazy_section/1" do
    test "shows the title and a loading line until the read returns" do
      html = render_lazy_section(%{state: nil})

      assert text(html, "summary") == "Tables"
      assert count(html, "summary[phx-click='load_tables'][phx-value-section='tables']") == 1
      assert text(html, "details > p") == "Loading..."
      assert count(html, "#value") == 0
    end

    test "renders what the read returned, with its count in the title" do
      html = render_lazy_section(%{state: {:ok, ["a", "b"]}})

      assert text(html, "summary") == "Tables (2)"
      assert text(html, "#value") == "a, b"
      refute text(html, "details") =~ "Loading..."
    end

    test "shows the error of a failed read" do
      html = render_lazy_section(%{state: {:error, "Failed to connect"}})

      assert text(html, "summary") == "Tables"
      assert text(html, "details > p.text-danger") == "Failed to connect"
      assert count(html, "#value") == 0
    end

    test "shows a warning after the title, and sends no section value without a section" do
      html = render_lazy_section(%{state: {:ok, []}, section: nil, warning: "1 broken"})

      assert text(html, "summary .text-danger") == "· 1 broken"
      assert count(html, "summary[phx-click='load_tables']") == 1
      assert count(html, "summary[phx-value-section]") == 0
    end
  end

  describe "table/1" do
    test "has a column per slot, with monospace cells only in code columns" do
      html = render_table(%{rows: [%{name: "a", acl: "x=r"}, %{name: "b", acl: "y=w"}]})

      assert texts(html, "th") == ["name", "acl"]
      assert texts(html, "tbody tr") == ["a x=r", "b y=w"]
      assert texts(html, "td.text-monospace") == ["x=r", "y=w"]
    end

    test "shows its empty text in one row across every column, and no row without one" do
      html = render_table(%{rows: [], empty: "None"})

      assert texts(html, "tbody td") == ["None"]
      assert html |> LazyHTML.query("tbody td") |> LazyHTML.attribute("colspan") == ["2"]

      assert count(render_table(%{rows: []}), "tbody tr") == 0
    end
  end

  defp render_lazy_section(assigns) do
    assigns = Map.merge(%{section: "tables", warning: nil}, assigns)

    parse(~H"""
    <.lazy_section
      :let={rows}
      id="tables-section"
      event="load_tables"
      section={@section}
      title="Tables"
      count={&length/1}
      state={@state}
    >
      <:warning :if={@warning}>{@warning}</:warning>
      <p id="value">{Enum.join(rows, ", ")}</p>
    </.lazy_section>
    """)
  end

  defp render_table(assigns) do
    assigns = Map.put_new(assigns, :empty, nil)

    parse(~H"""
    <.table rows={@rows} empty={@empty}>
      <:col :let={row} label="name">{row.name}</:col>
      <:col :let={row} label="acl" code>{row.acl}</:col>
    </.table>
    """)
  end

  # LazyHTML, like has_element?/3, so the text of an element reads the same as in TenantInfoTest.
  defp parse(rendered), do: rendered |> rendered_to_string() |> LazyHTML.from_fragment()

  defp count(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count()
  defp text(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> normalize()
  defp texts(html, selector), do: html |> LazyHTML.query(selector) |> Enum.map(&normalize(LazyHTML.text(&1)))

  defp normalize(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
