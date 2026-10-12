defmodule Realtime.Tenants.SqlLogexEnv do
  @moduledoc """
  Builds a `SqlLogex.Env` from the `Realtime.Tenants.Authorization` struct Realtime already has for a
  join, one per extension being checked.

  The settings map matches `Realtime.Tenants.Authorization.set_conn_config/2` byte-for-byte: the same
  `Jason.encode` on `claims` and on the header map, and the same `role` value used for both `"role"`
  and `"request.jwt.claim.role"` (`authorization.ex:370-382`). Anything else would make a shadow-mode
  mismatch meaningless, since it would be comparing against an input Postgres never actually saw.
  """

  alias Realtime.Tenants.Authorization
  alias SqlLogex.Env

  @doc """
  Builds the env for deciding `extension`. Fanning out over multiple extensions (a read checks
  `broadcast`, and `presence` when enabled) is the caller's job, not this function's.

  Returns `{:error, {:unsupported_extension, extension}}` for anything other than
  `t:Authorization.extension/0`, rather than raising: nothing in this pipeline raises into its caller.
  """
  @spec build(Authorization.t(), term()) :: {:ok, Env.t()} | {:error, term()}
  def build(%Authorization{topic: topic, headers: headers, claims: claims, role: role, sub: sub}, extension)
      when extension in [:broadcast, :presence, :persistence] do
    with {:ok, claims_json} <- Jason.encode(claims),
         {:ok, headers_json} <- headers |> Map.new() |> Jason.encode() do
      settings = %{
        "role" => role,
        "realtime.topic" => topic,
        "request.jwt.claims" => claims_json,
        "request.jwt.claim.sub" => sub,
        "request.jwt.claim.role" => role,
        "request.headers" => headers_json
      }

      row = %{"topic" => text_or_nil(topic), "extension" => {:text, Atom.to_string(extension)}}

      {:ok, Env.new(settings, row)}
    end
  end

  def build(%Authorization{}, extension), do: {:error, {:unsupported_extension, extension}}

  # SQL NULL, not {:text, nil}: what Postgres would see if topic_name were ever NULL, and the only
  # one of SqlLogex.Value's representations of NULL.
  defp text_or_nil(nil), do: nil
  defp text_or_nil(topic), do: {:text, topic}
end
