defmodule RealtimeWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """

  use RealtimeWeb, :controller
  use Realtime.Logs

  import RealtimeWeb.ErrorHelpers
  require Logger

  def call(conn, {:error, :not_found}) do
    log_error("TenantNotFound", "Tenant not found")
    maybe_capture_sentry_error(conn, "TenantNotFound", "Tenant not found")

    conn
    |> put_status(:not_found)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: "not found")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    details = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    log_error(
      "UnprocessableEntity",
      details
    )
    maybe_capture_sentry_error(conn, "UnprocessableEntity", details)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end

  def call(conn, {:error, status, message}) when is_atom(status) and is_binary(message) do
    log_error("UnprocessableEntity", message)
    maybe_capture_sentry_error(conn, "UnprocessableEntity", message)

    conn
    |> put_status(status)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: message)
  end

  def call(conn, {:error, %Ecto.Changeset{valid?: false} = changeset}) do
    details = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    log_error(
      "UnprocessableEntity",
      details
    )
    maybe_capture_sentry_error(conn, "UnprocessableEntity", details)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end

  def call(conn, {:error, _}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: "Unauthorized")
  end

  def call(conn, %Ecto.Changeset{valid?: false} = changeset) do
    details = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    log_error(
      "UnprocessableEntity",
      details
    )
    maybe_capture_sentry_error(conn, "UnprocessableEntity", details)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end

  def call(conn, response) do
    log_error("UnknownErrorOnController", response)
    maybe_capture_sentry_error(conn, "UnknownErrorOnController", response)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(RealtimeWeb.ErrorView)
    |> render("error.json", message: "Unknown error")
  end

  defp maybe_capture_sentry_error(conn, code, details) do
    if sampled?(Application.get_env(:realtime, :sentry_controller_error_sample_rate, 1.0)) do
      Sentry.capture_message("#{code}: controller error",
        level: :error,
        tags: %{error_code: code, source: "controller"},
        extra: %{
          method: conn.method,
          path: conn.request_path,
          request_id: Logger.metadata()[:request_id],
          details: details
        }
      )
    end
  end

  defp sampled?(rate) when is_float(rate), do: rate >= 1.0 or :rand.uniform() <= rate
  defp sampled?(rate) when is_integer(rate), do: sampled?(rate / 1)
  defp sampled?(_), do: false
end
