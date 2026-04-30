defmodule Ollama do
  @moduledoc """
  Manages an Ollama Docker container for `:live_llm` integration tests.

  Starts a single shared container, pulls a small model, and exposes the base URL.
  Tests gated with `@moduletag :live_llm` call `Ollama.ensure_ready/0` in their
  `setup_all` callback.

  Environment variables:
  - `OLLAMA_HOST`  — override the base URL (e.g. for a pre-existing instance).
                     Defaults to `http://localhost:11435` (non-standard port to
                     avoid colliding with a developer's local Ollama).
  - `OLLAMA_MODEL` — model to pull and use. Defaults to `qwen2:0.5b` (352 MB,
                     fast on CPU, valid OpenAI-compatible SSE output).
  """

  require Logger

  @image "ollama/ollama"
  @container_name "realtime-test-ollama"
  @default_host "http://localhost:11435"
  @default_model "qwen2:0.5b"
  @host_port 11_435

  @spec base_url() :: String.t()
  def base_url, do: System.get_env("OLLAMA_HOST", @default_host)

  @spec model() :: String.t()
  def model, do: System.get_env("OLLAMA_MODEL", @default_model)

  @spec ensure_ready() :: :ok | {:error, String.t()}
  def ensure_ready do
    with :ok <- ensure_container_running(),
         :ok <- wait_for_api(),
         :ok <- ensure_model_available() do
      :ok
    end
  end

  @spec stop() :: :ok
  def stop do
    System.cmd("docker", ["stop", @container_name])
    :ok
  end

  defp ensure_container_running do
    case System.get_env("OLLAMA_HOST") do
      nil ->
        case container_running?() do
          true ->
            :ok

          false ->
            pull_image()
            start_container()
        end

      _url ->
        :ok
    end
  end

  defp container_running? do
    {output, 0} = System.cmd("docker", ["ps", "--filter", "name=#{@container_name}", "--format", "{{.Names}}"])
    String.contains?(output, @container_name)
  end

  defp pull_image do
    case System.cmd("docker", ["image", "inspect", @image]) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("Pulling #{@image}. This might take a while...")
        {_, 0} = System.cmd("docker", ["pull", @image])
        :ok
    end
  end

  defp start_container do
    IO.puts("Starting Ollama container on port #{@host_port}...")

    System.cmd("docker", ["rm", "-f", @container_name])

    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--name",
        @container_name,
        "-p",
        "#{@host_port}:11434",
        @image
      ])

    :ok
  end

  defp wait_for_api(retries \\ 30) do
    url = base_url() <> "/api/tags"

    case Req.get(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(1_000)
        wait_for_api(retries - 1)

      _ ->
        {:error, "Ollama API did not become ready at #{url}"}
    end
  end

  defp ensure_model_available do
    m = model()
    url = base_url() <> "/api/tags"

    with {:ok, %{status: 200, body: body}} <- Req.get(url),
         models = get_in(body, ["models"]) || [],
         names = Enum.map(models, & &1["name"]) do
      if Enum.any?(names, &String.starts_with?(&1, m)) do
        :ok
      else
        pull_model(m)
      end
    else
      _ -> {:error, "Could not list Ollama models"}
    end
  end

  defp pull_model(m) do
    IO.puts("Pulling Ollama model #{m}. This will take a while on first run...")
    url = base_url() <> "/api/pull"

    case Req.post(url, json: %{"name" => m}, receive_timeout: :timer.minutes(10), retry: false) do
      {:ok, %{status: 200}} -> :ok
      {:error, reason} -> {:error, "Failed to pull model #{m}: #{inspect(reason)}"}
    end
  end
end
