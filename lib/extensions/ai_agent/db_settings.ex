defmodule Extensions.AiAgent.DbSettings do
  @moduledoc """
  Schema callbacks for the AI Agent extension.
  """

  def default do
    %{
      "max_concurrent_sessions" => 10
    }
  end

  # Each tuple: {field_name, validator_fn, encrypted?}
  def required do
    [
      {"protocol", &is_binary/1, false},
      {"base_url", &is_binary/1, false},
      {"model", &is_binary/1, false},
      {"api_key", &is_binary/1, true}
    ]
  end
end
