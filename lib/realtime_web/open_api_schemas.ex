defmodule RealtimeWeb.OpenApiSchemas do
  @moduledoc """
  Provides schemas and response definitions for RealtimeWeb OpenAPI specification.
  """

  alias OpenApiSpex.Schema

  defmodule TenantParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        tenant: %Schema{
          type: :object,
          properties: %{
            external_id: %Schema{type: :string, description: "External ID"},
            name: %Schema{type: :string, description: "Tenant name"},
            jwt_secret: %Schema{type: :string, description: "JWT secret"},
            max_concurrent_users: %Schema{
              type: :number,
              description: "Maximum connected concurrent clients"
            },
            max_events_per_second: %Schema{
              type: :number,
              description: "Maximum events, or messages, per second"
            },
            postgres_cdc_default: %Schema{
              type: :string,
              description: "Default Postgres CDC extension"
            },
            max_bytes_per_second: %Schema{type: :number, description: "Maximum bytes per second"},
            max_channels_per_client: %Schema{
              type: :number,
              description: "Maximum channels per WebSocket connection"
            },
            max_joins_per_second: %Schema{
              type: :number,
              description: "Maximum channel joins per second"
            },
            extensions: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  type: %Schema{type: :string, description: "Postgres CDC extension type"},
                  settings: %Schema{
                    type: :object,
                    description: "Extension database configuration"
                  },
                  tenant_external_id: %Schema{type: :string, description: "Tenant external ID"}
                },
                required: [
                  :settings,
                  :tenant_external_id
                ]
              }
            }
          },
          required: [
            :external_id,
            :jwt_secret
          ]
        }
      },
      required: [:tenant],
      example: %{
        tenant: %{
          external_id: "tenant-1",
          name: "First Tenant",
          jwt_secret: "4a218613-b539-4c52-adaa-64b14b25ee88",
          max_concurrent_users: 1000,
          max_events_per_second: 1000,
          postgres_cdc_default: "postgres_cdc_rls",
          max_bytes_per_second: 1000,
          max_channels_per_client: 100,
          max_joins_per_second: 1000,
          extensions: [
            %{
              type: "postgres_cdc_rls",
              settings: %{
                "region" => "us-west-1",
                "db_host" => "db_host",
                "db_name" => "postgres",
                "db_port" => "5432",
                "db_user" => "postgres",
                "slot_name" => "supabase_realtime_replication_slot",
                "ip_version" => 4,
                "db_password" => "password",
                "publication" => "supabase_realtime",
                "poll_interval_ms" => 100,
                "poll_max_changes" => 100,
                "poll_max_record_bytes" => 1_048_576
              },
              tenant_external_id: "tenant-1"
            }
          ]
        }
      }
    })

    def params(), do: {"Tenant Params", "application/json", __MODULE__}
  end

  defmodule TenantResponseValue do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "UUID"},
        external_id: %Schema{type: :string, description: "External ID"},
        name: %Schema{type: :string, description: "Tenant name"},
        max_concurrent_users: %Schema{
          type: :number,
          description: "Maximum connected concurrent clients"
        },
        inserted_at: %Schema{type: :string, format: "date-time", description: "Insert timestamp"},
        extensions: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              type: %Schema{type: :string, description: "Postgres CDC extension type"},
              settings: %Schema{type: :object, description: "Extension database configuration"},
              tenant_external_id: %Schema{type: :string, description: "Tenant external ID"},
              inserted_at: %Schema{
                type: :string,
                format: "date-time",
                description: "Insert timestamp"
              },
              updated_at: %Schema{
                type: :string,
                format: "date-time",
                description: "Update timestamp"
              }
            },
            required: [
              :settings,
              :tenant_external_id
            ]
          }
        }
      },
      required: [
        :external_id,
        :jwt_secret
      ],
      example: %{
        id: "d4448862-666f-4af2-9966-78298e8af6bf",
        external_id: "tenant-1",
        name: "First Tenant",
        max_concurrent_users: 1000,
        inserted_at: "2023-01-01T00:00:00Z",
        extensions: [
          %{
            type: "postgres_cdc_rls",
            settings: %{
              "region" => "us-west-1",
              "db_host" => "db_host",
              "db_name" => "postgres",
              "db_port" => "5432",
              "db_user" => "postgres",
              "slot_name" => "supabase_realtime_replication_slot",
              "ip_version" => 4,
              "db_password" => "password",
              "publication" => "supabase_realtime",
              "poll_interval_ms" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576
            },
            tenant_external_id: "tenant-1",
            inserted_at: "2023-01-01T00:00:00Z",
            updated_at: "2023-01-01T00:00:00Z"
          }
        ]
      }
    })
  end

  defmodule TenantResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{data: TenantResponseValue}
    })

    def response(), do: {"Tenant Response", "application/json", __MODULE__}
  end

  defmodule TenantResponseList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{data: %Schema{type: :array, items: TenantResponseValue}}
    })

    def response(), do: {"Tenant List Response", "application/json", __MODULE__}
  end

  defmodule EmptyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :string,
      default: ""
    })

    def response(), do: {"Empty Response", "application/json", __MODULE__}
  end

  defmodule NotFoundResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        error: %Schema{type: :string, default: "not found"}
      }
    })

    def response(), do: {"Not Found", "application/json", __MODULE__}
  end
end
