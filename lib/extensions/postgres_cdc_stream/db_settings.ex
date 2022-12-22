defmodule Extensions.PostgresCdcStream.DbSettings do
  @moduledoc """
  Schema callbacks for CDC Stream implementation.
  """

  @spec default :: map()
  def default() do
    %{
      "publication" => "supabase_realtime",
      "slot_name" => "supabase_realtime_replication_slot",
      "ip_version" => 4,
      "dynamic_slot" => false
    }
  end

  @spec required :: [{String.t(), fun(), boolean()}]
  def required() do
    [
      {"region", &is_binary/1, false},
      {"db_host", &is_binary/1, true},
      {"db_name", &is_binary/1, true},
      {"db_user", &is_binary/1, true},
      {"db_port", &is_binary/1, true},
      {"db_password", &is_binary/1, true},
      {"ip_version", &is_integer/1, false}
    ]
  end
end
