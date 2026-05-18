defmodule Realtime.Api.Extensions do
  @moduledoc """
  Schema for Realtime Extension settings.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Bitwise

  alias Realtime.Crypto

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:type, :name, :inserted_at, :updated_at, :settings]}
  schema "extensions" do
    field(:type, :string)
    field(:name, :string)
    field(:settings, :map)
    belongs_to(:tenant, Realtime.Api.Tenant, foreign_key: :tenant_external_id, type: :string)
    timestamps()
  end

  def changeset(extension, attrs) do
    {attrs, required_settings} =
      case attrs["type"] do
        nil ->
          {attrs, []}

        type ->
          %{default: default, required: required} = Realtime.Extensions.db_settings(type)
          {%{attrs | "settings" => Map.merge(default, attrs["settings"])}, required}
      end

    extension
    |> cast(attrs, [:type, :name, :tenant_external_id, :settings])
    |> validate_required([:type, :settings])
    |> unique_constraint([:tenant_external_id, :type, :name])
    |> validate_ai_agent()
    |> validate_required_settings(required_settings)
    |> encrypt_settings(required_settings)
  end

  @blocked_cidrs [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{0, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10}
  ]

  defp validate_ai_agent(changeset) do
    if get_field(changeset, :type) == "ai_agent" do
      changeset
      |> validate_required([:name])
      |> validate_change(:settings, &validate_base_url_settings/2)
      |> validate_change(:settings, &validate_header_settings/2)
      |> validate_change(:settings, &validate_system_prompt_settings/2)
    else
      changeset
    end
  end

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)
  @dns_timeout_ms 1_000

  defp validate_base_url_settings(_, %{"base_url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        check_https_host(host)

      %URI{scheme: "http", host: host} when host in @loopback_hosts ->
        []

      %URI{scheme: "http"} ->
        [{:settings, "base_url with http scheme is only permitted for loopback hosts (localhost, 127.0.0.1)"}]

      _ ->
        [{:settings, "base_url must use https scheme"}]
    end
  end

  defp validate_base_url_settings(_, %{"base_url" => nil}), do: []
  defp validate_base_url_settings(_, %{"base_url" => _}), do: [{:settings, "base_url must be a string"}]
  defp validate_base_url_settings(_, _), do: []

  defp validate_system_prompt_settings(_, %{"system_prompt" => v}) when is_binary(v), do: []
  defp validate_system_prompt_settings(_, %{"system_prompt" => nil}), do: []
  defp validate_system_prompt_settings(_, %{"system_prompt" => _}), do: [{:settings, "system_prompt must be a string"}]
  defp validate_system_prompt_settings(_, _), do: []

  defp validate_header_settings(_, settings) do
    Enum.flat_map(["http_referer", "x_title"], fn key ->
      case settings[key] do
        nil ->
          []

        v when is_binary(v) ->
          if String.contains?(v, ["\r", "\n"]), do: [{:settings, "#{key} contains invalid characters"}], else: []

        _ ->
          [{:settings, "#{key} must be a string"}]
      end
    end)
  end

  defp check_https_host(host) do
    case Realtime.DNS.getaddrs(String.to_charlist(host), :inet, @dns_timeout_ms) do
      {:ok, ips} ->
        if Enum.any?(ips, &private_ip?/1),
          do: [{:settings, "base_url resolves to a private or reserved address"}],
          else: []

      {:error, _} ->
        [{:settings, "base_url host cannot be resolved"}]
    end
  end

  defp private_ip?(ip) do
    ip_int = ip_to_int(ip)
    Enum.any?(@blocked_cidrs, fn {network, prefix_len} -> in_cidr?(ip_int, ip_to_int(network), prefix_len) end)
  end

  defp ip_to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp in_cidr?(ip_int, network_int, prefix_len) do
    mask = 0xFFFFFFFF <<< (32 - prefix_len) &&& 0xFFFFFFFF
    (ip_int &&& mask) == (network_int &&& mask)
  end

  def encrypt_settings(changeset, required) do
    update_change(changeset, :settings, fn settings ->
      Enum.reduce(required, settings, fn
        {field, _, true}, acc -> %{acc | field => Crypto.encrypt!(settings[field])}
        _, acc -> acc
      end)
    end)
  end

  def validate_required_settings(changeset, required) do
    validate_change(changeset, :settings, fn _, value ->
      Enum.reduce(required, [], fn {field, checker, _}, acc ->
        case value[field] do
          nil -> [{:settings, "#{field} can't be blank"} | acc]
          data -> if checker.(data), do: acc, else: [{:settings, "#{field} is invalid"} | acc]
        end
      end)
    end)
  end
end
