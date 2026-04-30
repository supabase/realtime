defmodule Realtime.Api.Extensions do
  @moduledoc """
  Schema for Realtime Extension settings.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Bitwise, only: [bsl: 2, band: 2, bor: 2], warn: false

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
    {attrs1, required_settings} =
      case attrs["type"] do
        nil ->
          {attrs, []}

        type ->
          %{default: default, required: required} = Realtime.Extensions.db_settings(type)

          {
            %{attrs | "settings" => Map.merge(default, attrs["settings"])},
            required
          }
      end

    extension
    |> cast(attrs1, [:type, :name, :tenant_external_id, :settings])
    |> validate_required([:type, :settings])
    |> unique_constraint([:tenant_external_id, :type, :name])
    |> validate_name_for_ai_agent()
    |> validate_ai_agent_base_url()
    |> validate_ai_agent_header_values()
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

  defp validate_name_for_ai_agent(changeset) do
    if get_field(changeset, :type) == "ai_agent" do
      validate_required(changeset, [:name])
    else
      changeset
    end
  end

  defp validate_ai_agent_base_url(changeset) do
    if get_field(changeset, :type) != "ai_agent", do: changeset, else: do_validate_base_url(changeset)
  end

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)
  @dns_timeout_ms 1_000

  defp do_validate_base_url(changeset) do
    validate_change(changeset, :settings, fn _, settings ->
      case settings["base_url"] do
        nil ->
          []

        url when is_binary(url) ->
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

        _ ->
          [{:settings, "base_url must be a string"}]
      end
    end)
  end

  defp check_https_host(host) do
    task = Task.async(fn -> :inet.getaddrs(String.to_charlist(host), :inet) end)

    case Task.await(task, @dns_timeout_ms) do
      {:ok, ips} ->
        if Enum.any?(ips, &private_ip?/1),
          do: [{:settings, "base_url resolves to a private or reserved address"}],
          else: []

      {:error, _} ->
        [{:settings, "base_url host cannot be resolved"}]
    end
  catch
    :exit, _ -> [{:settings, "base_url host cannot be resolved"}]
  end

  defp validate_ai_agent_header_values(changeset) do
    if get_field(changeset, :type) != "ai_agent", do: changeset, else: do_validate_headers(changeset)
  end

  defp do_validate_headers(changeset) do
    validate_change(changeset, :settings, fn _, settings ->
      ["http_referer", "x_title"]
      |> Enum.flat_map(fn key ->
        case settings[key] do
          nil ->
            []

          v when is_binary(v) ->
            if String.contains?(v, ["\r", "\n"]), do: [{:settings, "#{key} contains invalid characters"}], else: []

          _ ->
            [{:settings, "#{key} must be a string"}]
        end
      end)
    end)
  end

  defp private_ip?(ip) do
    Enum.any?(@blocked_cidrs, fn {network, prefix_len} ->
      ip_to_int(ip) |> in_cidr?(ip_to_int(network), prefix_len)
    end)
  end

  defp ip_to_int({a, b, c, d}), do: bor(bor(bor(bsl(a, 24), bsl(b, 16)), bsl(c, 8)), d)

  defp in_cidr?(ip_int, network_int, prefix_len) do
    mask = band(bsl(0xFFFFFFFF, 32 - prefix_len), 0xFFFFFFFF)
    band(ip_int, mask) == band(network_int, mask)
  end

  def encrypt_settings(changeset, required) do
    update_change(changeset, :settings, fn settings ->
      Enum.reduce(required, settings, fn
        {field, _, true}, acc ->
          encrypted = Crypto.encrypt!(settings[field])
          %{acc | field => encrypted}

        _, acc ->
          acc
      end)
    end)
  end

  def validate_required_settings(changeset, required) do
    validate_change(changeset, :settings, fn
      _, value ->
        Enum.reduce(required, [], fn {field, checker, _}, acc ->
          case value[field] do
            nil ->
              [{:settings, "#{field} can't be blank"} | acc]

            data ->
              if checker.(data) do
                acc
              else
                [{:settings, "#{field} is invalid"} | acc]
              end
          end
        end)
    end)
  end
end
