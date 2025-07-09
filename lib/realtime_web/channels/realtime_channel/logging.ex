defmodule RealtimeWeb.RealtimeChannel.Logging do
  @moduledoc """
  Log functions for Realtime channels to ensure
  """
  use Realtime.Logs

  alias Realtime.Telemetry

  @doc """
  Checks if the log level set in the socket is less than or equal to the given level of the message to be logged.
  """
  @spec maybe_log(socket :: Phoenix.Socket.t(), level :: Logger.level(), code :: binary(), msg :: binary()) :: :ok
  def maybe_log(%{assigns: %{log_level: log_level, tenant: tenant}}, level, code, msg) do
    Logger.metadata(external_id: tenant, project: tenant)
    msg = stringify!(msg)
    if Logger.compare_levels(log_level, level) != :gt, do: Logger.log(level, "#{code}: #{msg}")
  end

  def maybe_log_error(socket, code, msg), do: maybe_log(socket, :error, code, msg)
  def maybe_log_warning(socket, code, msg), do: maybe_log(socket, :warning, code, msg)

  def maybe_log_info(%{assigns: %{log_level: log_level, tenant: tenant}}, msg) do
    Logger.metadata(external_id: tenant, project: tenant)
    if Logger.compare_levels(log_level, :info) != :gt, do: Logger.info(inspect(msg))
  end

  @doc """
  Logs an error with token metadata
  """
  @spec log_error_with_token_metadata(code :: binary(), msg :: binary(), token :: Joken.bearer_token()) ::
          {:error, %{reason: binary()}}
  def log_error_with_token_metadata(code, msg, token) do
    metadata = Logger.metadata()
    metadata = update_metadata_with_token_claims(metadata, token)
    log_error_message(:error, code, msg, metadata)
  end

  @doc """
  Logs an error with token metadata
  """
  @spec log_warning_with_token_metadata(
          code :: binary(),
          msg :: binary(),
          token :: Joken.bearer_token(),
          metadata :: keyword()
        ) :: {:error, %{reason: binary()}}
  def log_warning_with_token_metadata(code, msg, token, metadata \\ []) do
    if metadata == [], do: Logger.metadata()
    metadata = update_metadata_with_token_claims(metadata, token)
    log_error_message(:warning, code, msg, metadata)
  end

  defp update_metadata_with_token_claims(metadata, token) do
    case Joken.peek_claims(token) do
      {:ok, claims} ->
        sub = Map.get(claims, "sub")
        exp = Map.get(claims, "exp")
        iss = Map.get(claims, "iss")
        metadata ++ [sub: sub, exp: exp, iss: iss]

      _ ->
        metadata
    end
  end

  @doc """
  Logs messages according to user options given on config
  """
  def maybe_log_handle_info(
        %{assigns: %{log_level: log_level, channel_name: channel_name, tenant: tenant}} = socket,
        msg
      ) do
    Logger.metadata(external_id: tenant, project: tenant)

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
          keyword()
        ) :: {:error, %{reason: binary()}}
  def log_error_message(level, code, error, metadata \\ [])

  def log_error_message(:error, code, error, metadata) do
    if code in system_errors(), do: Telemetry.execute([:realtime, :channel, :error], %{code: code}, %{code: code})

    log_error(code, error, metadata)
    {:error, %{reason: error}}
  end

  def log_error_message(:warning, code, error, metadata) do
    log_warning(code, error, metadata)
    {:error, %{reason: error}}
  end
end
