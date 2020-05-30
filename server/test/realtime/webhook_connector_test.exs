defmodule Realtime.WebhookConnectorTest do
  use ExUnit.Case

  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.Configuration
  alias Realtime.TransactionFilter.Filter
  alias Realtime.WebhookConnector

  test "notify calls notification function after filtering the handlers" do
    {:ok, call_counter} = Agent.start_link fn -> 0 end
    notify = fn (_, _) ->
      Agent.update(call_counter, fn c -> c + 1 end)
      Task.async(fn ->
	{:ok, %{status_code: 200}}
      end)
    end

    txn = %Transaction{
      changes: [
	%Realtime.Adapters.Changes.NewRecord{
	  columns: [
	    %Realtime.Decoder.Messages.Relation.Column{flags: [:key], name: "id", type: "int8", type_modifier: 4294967295},
	    %Realtime.Decoder.Messages.Relation.Column{flags: [], name: "details", type: "text", type_modifier: 4294967295},
	    %Realtime.Decoder.Messages.Relation.Column{flags: [], name: "user_id", type: "int8", type_modifier: 4294967295}
	  ],
	  commit_timestamp: nil,
	  record: %{"details" => "The SCSI system is down, program the haptic microchip so we can back up the SAS circuit!", "id" => "14", "user_id" => "1"},
	  schema: "public",
	  table: "todos",
	  type: "INSERT",
        }
      ]
    }

    get_config = fn _ ->
      config = [
	%Configuration.Webhook{ # will match
	  event: "*",
	  relation: "*",
        }, %Configuration.Webhook { # will match
	  event: "INSERT",
	  relation: "public:todos",
        }, %Configuration.Webhook { # won't match
	  event: "UPDATE",
	  relation: "public:todos",
        },
      ]
      {:ok, config}
    end

    state = %WebhookConnector.State{
      notify: notify,
      get_config: get_config
    }

    WebhookConnector.handle_call({:notify, txn}, nil, state)

    call_count = Agent.get(call_counter, & &1)
    assert call_count == 2
    Agent.stop(call_counter)
  end
end
