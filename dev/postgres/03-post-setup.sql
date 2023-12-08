ALTER ROLE postgres
SET search_path TO "\$user",
    public,
    extensions;
CREATE OR REPLACE FUNCTION extensions.notify_api_restart() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN NOTIFY pgrst,
    'reload schema';
END;
$$;
CREATE EVENT TRIGGER api_restart ON ddl_command_end EXECUTE PROCEDURE extensions.notify_api_restart();
COMMENT ON FUNCTION extensions.notify_api_restart IS 'Sends a notification to the API to restart. If your database schema has changed, this is required so that Supabase can rebuild the relationships.';