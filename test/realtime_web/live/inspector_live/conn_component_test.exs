defmodule RealtimeWeb.InspectorLive.ConnComponentTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "connection form persistence" do
    test "validate never patches the URL with token or bearer, regardless of which field changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#conn_form", connection: %{channel: "room_b", token: "secret-token", bearer: "secret-bearer"})
      |> render_change()

      path = assert_patch(view)

      refute path =~ "secret-token"
      refute path =~ "secret-bearer"
      assert path =~ "room_b"
    end

    test "editing project derives host without leaking secrets into the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#conn_form", connection: %{project: "abcdefgh", token: "secret-token"})
      |> render_change()

      path = assert_patch(view)

      assert path =~ "abcdefgh.supabase.co"
      refute path =~ "secret-token"
    end

    test "share link never contains the token or bearer even after connecting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#conn_form",
        connection: %{channel: "room_a", host: "https://x.supabase.co", token: "secret-token", bearer: "secret-bearer"}
      )
      |> render_submit()

      html = render(view)
      [share_url] = html |> Floki.parse_document!() |> Floki.attribute("#share-button", "data-url")

      refute share_url =~ "secret-token"
      refute share_url =~ "secret-bearer"
    end
  end

  describe "connect validation" do
    test "connecting without a token shows a required-field error and does not push connect", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#conn_form", connection: %{channel: "room_a", host: "https://x.supabase.co", token: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "connecting without a project or host shows a required-field error on project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#conn_form", connection: %{channel: "room_a", token: "a-token", project: "", host: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "connecting with just a host (no project) succeeds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#conn_form", connection: %{channel: "room_a", token: "a-token", host: "https://x.supabase.co"})
      |> render_submit()

      assert_push_event(view, "connect", %{"connection" => %{"channel" => "room_a"}})
    end
  end
end
