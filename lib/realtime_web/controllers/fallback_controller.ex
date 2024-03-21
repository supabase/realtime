defmodule RealtimeWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use RealtimeWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: "Not found")
  end

  def call(conn, {:error, _}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: "Unauthorized")
  end

  def call(conn, {:error, status, message}) when is_atom(status) and is_binary(message) do
    conn
    |> put_status(status)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: message)
  end

  def call(conn, %Ecto.Changeset{valid?: false} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end
end
