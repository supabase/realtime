defmodule MultiplayerWeb.HooksView do
  use MultiplayerWeb, :view
  alias MultiplayerWeb.HooksView

  def render("index.json", %{hooks: hooks}) do
    %{data: render_many(hooks, HooksView, "hooks.json")}
  end

  def render("show.json", %{hooks: hooks}) do
    %{data: render_one(hooks, HooksView, "hooks.json")}
  end

  def render("hooks.json", %{hooks: hooks}) do
    %{id: hooks.id,
      type: hooks.type,
      event: hooks.event,
      url: hooks.url}
  end
end
