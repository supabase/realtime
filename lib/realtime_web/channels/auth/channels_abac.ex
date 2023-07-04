defmodule RealtimeWeb.ChannelsAbac do
  @doc """
  Get the abac rules for all features and subfeatures of the Realtime product.

  ## Examples

  Realtime:
      iex> %{"name" => "realtime"} = RealtimeWeb.ChannelsAbac.example_abac_one() |> RealtimeWeb.ChannelsAbac.get_realtime_rules()
  """
  def get_realtime_rules(abac) do
    abac
    |> Map.get("features")
    |> Enum.find(&(&1["name"] == "realtime"))
  end

  @doc """
  Get abac rules for a Realtime Channel.

  ## Examples

  Realtime:
      iex> channel_name = "my-channel-update-counters"
      iex> realtime_rules = RealtimeWeb.ChannelsAbac.example_abac_one() |> RealtimeWeb.ChannelsAbac.get_realtime_rules()
      iex> %{"name" => "my-channel-update-counters"} = RealtimeWeb.ChannelsAbac.get_channel_rules(realtime_rules, channel_name)
  """

  def get_channel_rules(realtime_rules, channel_name) do
    realtime_rules
    |> Map.get("features")
    |> Enum.find(&(&1["name"] == "channels"))
    |> Map.get("features")
    |> Enum.find(&(&1["name"] == channel_name))
  end

  @doc """
  Get the abac rules for a Realtime Channel event.

  ## Examples

  Broadcast:

      iex> channel_rules = %{
      ...>"name" => "my-channel-update-counters",
      ...>  "attrs" => ["read"],
      ...>  "features" => [
      ...>    %{
      ...>      "name" => "broadcast",
      ...>      "attrs" => ["read"],
      ...>      "features" => []
      ...>    }
      ...>  ]
      ...>}
      iex> %{"attrs" => ["read"]} = RealtimeWeb.ChannelsAbac.get_rules(channel_rules, "broadcast")
  """

  def get_rules(channel_rules, event) do
    channel_rules
    |> Map.get("features")
    |> Enum.find(&(&1["name"] == event))
  end

  @doc """
  Initial ideas for abac rules.
  """
  def example_abac() do
    [
      %{
        "realtime" => %{
          "channels" => [
            %{
              "name" => "my-channel-update-counters",
              "broadcast" => %{"attrs" => ["read"]}
            },
            %{
              "name" => "my-people-presences",
              "presence" => %{"attrs" => ["read", "write"]}
            },
            %{
              "name" => "my-team-channel",
              "postgres_changes" => %{
                "attrs" => ["read"],
                "filters" => [
                  %{"op" => "eq", "value" => 1, "field" => "id", "attrs" => ["read"]},
                  %{"op" => "lt", "value" => 10, "field" => "rank", "attrs" => ["read"]}
                ]
              }
            }
          ]
        }
      },
      %{
        "storage" => [
          %{"storage-feature" => %{"attrs" => ["read", "write"]}}
        ]
      }
    ]
  end

  @doc """
  Current idea: "feature" all the way down
  """

  def example_abac_one() do
    %{
      "features" => [
        %{
          "name" => "realtime",
          "attrs" => ["read, write"],
          "features" => [
            %{
              "name" => "channels",
              "attrs" => ["read", "write"],
              "features" => [
                %{
                  "name" => "my-team-channel",
                  "attrs" => ["read", "write"],
                  "features" => [
                    %{
                      "name" => "postgres_changes",
                      "roles" => ["read"],
                      "features" => [
                        %{"name" => "id=eq.1", "attrs" => ["read"], "features" => [] "meta" => %{}},
                        %{"name" => "rank=lt.10", "attrs" => ["read"], "features" => []}
                      ]
                    }
                  ]
                },
                %{
                  "name" => "my-people-presences",
                  "attrs" => ["read", "write"],
                  "features" => [
                    %{"name" => "presence", "attrs" => ["read", "write"], "features" => []}
                  ]
                },
                %{
                  "name" => "my-channel-update-counters",
                  "attrs" => ["read"],
                  "features" => [
                    %{
                      "name" => "broadcast",
                      "attrs" => ["read"],
                      "features" => []
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

  def stas_abac() do
    %{
      "attrs" => [
        %{
          "name" => "realtime",
          "roles" => [],
          "attrs" => [
            %{
              "name" => "channels",
              "roles" => [],
              "attrs" => [
                %{
                  "name" => "my-team-channel",
                  "roles" => ["read", "write"],
                  "attrs" => [
                    %{
                      "name" => "postgres_changes",
                      "roles" => ["read"],
                      "attrs" => [
                        %{"name" => "id=eq.1", "roles" => ["read"], "attrs" => []},
                        %{"name" => "rank=lt.10", "roles" => ["read"], "attrs" => []}
                      ]
                    }
                  ]
                },
                %{
                  "name" => "my-people-presences",
                  "roles" => ["read", "write"],
                  "attrs" => [
                    %{"name" => "presence", "roles" => ["read", "write"], "attrs" => []}
                  ]
                },
                %{
                  "name" => "my-channel-update-counters",
                  "roles" => ["read"],
                  "attrs" => [
                    %{
                      "name" => "broadcast",
                      "roles" => ["read"],
                      "attrs" => []
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

end
