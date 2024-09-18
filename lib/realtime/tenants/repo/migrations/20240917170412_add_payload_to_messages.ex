defmodule Realtime.Tenants.Migrations.AddPayloadToMessages do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add_if_not_exists :payload, :map
      add_if_not_exists :event, :text
      add_if_not_exists :topic, :text
      add_if_not_exists :private, :boolean, default: true
      modify :inserted_at, :utc_datetime, default: fragment("now()")
      modify :updated_at, :utc_datetime, default: fragment("now()")
    end

    execute """
    CREATE OR REPLACE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean DEFAULT true)
    RETURNS void
    AS $$
    BEGIN
        INSERT INTO realtime.messages (payload, event, topic, private, extension)
        VALUES (payload, event, topic, private, 'broadcast');
    END;
    $$
    LANGUAGE plpgsql;
    """

    execute """
    CREATE OR REPLACE FUNCTION realtime.broadcast_change ()
        RETURNS TRIGGER
        AS $$
    DECLARE
        -- Declare a variable to hold the JSONB representation of the row
        row_data jsonb := '{}'::jsonb;
        -- Declare entry that will be written to the realtime.messages table
        topic_name text := TG_ARGV[0]::text;
        event_name text := COALESCE(TG_ARGV[1]::text, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME);
    BEGIN
        -- Ensure trigger is not called for statements
        IF TG_LEVEL = 'STATEMENT' THEN
            RAISE EXCEPTION 'realtime.broadcast_changes should be triggered for each row, not for each statement';
        END IF;
        -- Ensure topic_name is provided
        IF topic_name IS NULL THEN
            RAISE EXCEPTION 'Topic name must be provided';
        END IF;
        -- Check the operation type and handle accordingly
        IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
            row_data := jsonb_build_object('old_record', OLD, 'record', NEW, 'operation', TG_OP, 'table', TG_TABLE_NAME, 'schema', TG_TABLE_SCHEMA);
            PERFORM realtime.send (row_data, event_name, topic_name);
            RETURN NULL;
        ELSE
            RAISE EXCEPTION 'Unexpected operation type: %', TG_OP;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Failed to process the row: %', SQLERRM;
    END;

    $$
    LANGUAGE plpgsql;
    """
  end
end
