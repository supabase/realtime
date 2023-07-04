defmodule RealtimeWeb.ChannelsAbac do
  def get_realtime_rules(abac) do
    abac
    |> Map.get("features")
    |> Enum.filter(&(&1["name"] == "realtime"))
  end

  def get_channel_rules(realtime_rules, channel_name) do
    realtime_rules
    |> Map.get("features")
    |> Enum.filter(&(&1["name"] == "channels"))
    |> Enum.find(&(&1["name"] == channel_name))
  end

  @doc """
  Get the abac rules for Broadcast.

  ## Examples

  Broadcast attrs:

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
      iex> %{"attrs" => ["read"]} = RealtimeWeb.ChannelsAbac.get_broadcast_rules(channel_rules)
  """

  def get_broadcast_rules(channel_rules) do
    channel_rules
    |> Map.get("features")
    |> Enum.find(&(&1["name"] == "broadcast"))
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
                      "attrs" => ["read"],
                      "features" => [
                        %{"name" => "id=eq.1", "attrs" => ["read"], "features" => []},
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
end
