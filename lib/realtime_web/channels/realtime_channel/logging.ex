defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels to ensure
  """
  use Realtime.Logs

  alias Realtime.Telemetry

  @doc """
  Checks if the log level set in the socket is less than or equal to the given level of the message to be logged.
  """
  @spec maybe_log(
          socket :: Phoenix.Socket.t(),
          level :: Logger.level(),
          code :: binary(),
          msg :: binary(),
          metadata :: keyword()
        ) :: :ok
  def maybe_log(%{assigns: %{log_level: log_level}}, level, code, msg, metadata \\ []) do
    metadata = if metadata == [], do: Logger.metadata()

    msg = stringify!(msg)

    if Logger.compare_levels(log_level, level) != :gt do
      Logger.log(level, "#{code}: #{msg}", metadata)
    end
  end

  def maybe_log_error(socket, code, msg, metadata \\ []), do: maybe_log(socket, :error, code, msg, metadata)
  def maybe_log_warning(socket, code, msg, metadata \\ []), do: maybe_log(socket, :warning, code, msg, metadata)

  def maybe_log_info(%{assigns: %{log_level: log_level}}, msg, metadata \\ []) do
    metadata = if metadata == [], do: Logger.metadata()

    if Logger.compare_levels(log_level, :info) != :gt do
      Logger.info(inspect(msg), metadata)
    end
  end

  @doc """
  Logs an error with token metadata
  """
  @spec log_error_with_token_metadata(
          code :: binary(),
          msg :: binary(),
          socket :: Phoenix.Socket.t()
        ) :: {:error, %{reason: binary()}}
  def log_error_with_token_metadata(code, msg, %{assigns: %{access_token: access_token, tenant: tenant_id}} = socket) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    update_metadata_with_token_claims(access_token)
    log_error_message(:error, code, msg, socket)
  end

  @doc """
  Logs an error with token metadata
  """
  @spec log_warning_with_token_metadata(
          code :: binary(),
          msg :: binary(),
          socket :: Phoenix.Socket.t()
        ) :: {:error, %{reason: binary()}}
  def log_warning_with_token_metadata(code, msg, %{assigns: %{access_token: access_token, tenant: tenant_id}} = socket) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    update_metadata_with_token_claims(access_token)
    log_error_message(:error, code, msg, socket)
  end

  defp update_metadata_with_token_claims(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} ->
        sub = Map.get(claims, "sub")
        exp = Map.get(claims, "exp")
        iss = Map.get(claims, "iss")

        Logger.metadata(sub: sub, exp: exp, iss: iss)

      _ ->
        nil
    end
  end

  @doc """
  Logs messages according to user options given on config
  """
  def maybe_log_handle_info(
        %{assigns: %{log_level: log_level, channel_name: channel_name}} = socket,
        msg
      ) do
    if Logger.compare_levels(log_level, :info) == :eq do
      msg = stringify!(msg)

      msg = "Received message on " <> channel_name <> " with payload: " <> msg
      Logger.log(log_level, msg)
    end

    socket
  end

  defp stringify!(msg) do
    case msg do
      msg when is_binary(msg) -> msg
      _ -> inspect(msg, pretty: true)
    end
  end

  @doc """
  List of errors that are system triggered and not user driven
  """
  def system_errors,
    do: [
      "UnableToSetPolicies",
      "InitializingProjectConnection",
      "DatabaseConnectionIssue",
      "UnknownErrorOnChannel"
    ]

  @doc """
  Logs errors in an expected format
  """
  @spec log_error_message(
          level :: :error | :warning,
          code :: binary(),
          error :: term(),
          socket :: Phoenix.Socket.t()
        ) :: {:error, %{reason: binary()}}
  def log_error_message(level, code, error, socket)

  def log_error_message(:error, code, error, %{assigns: %{tenant: tenant_id}}) do
    if code in system_errors(), do: Telemetry.execute([:realtime, :channel, :error], %{code: code}, %{code: code})
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    log_error(code, error, Logger.metadata())
    {:error, %{reason: error}}
  end

  def log_error_message(:warning, code, error, %{assigns: %{tenant: tenant_id}}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    log_warning(code, error, Logger.metadata())
    {:error, %{reason: error}}
  end
end
