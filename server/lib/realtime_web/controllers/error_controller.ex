defmodule RealtimeWeb.ErrorController do
  use RealtimeWeb, :controller

  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    Logger.debug("ErrorController.call(Changeset): #{inspect changeset}")
    conn
    |> put_status(:bad_request)
    |> json(changeset_errors_json(changeset))
  end

  def call(conn, {:not_found, id}) do
    conn
    |> put_status(:not_found)
    |> json(%{message: "not found", id: id})
  end

  def call(conn, error) do
    Logger.debug("ErrorController.call: #{inspect error}")
    conn
    |> put_status(:internal_server_error)
    |> json(%{message: "internal server error"})
  end

  defp changeset_errors_json(changeset) do
    errors_json =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          value =
            case value do
              {:parameterized, _, _} -> "" # Ecto.Enum fail to produce an error message
              _ -> to_string(value)
            end
          String.replace(acc, "%{#{key}}", value)
        end)
      end)
    %{message: "invalid fields values", errors: errors_json}
  end
end
