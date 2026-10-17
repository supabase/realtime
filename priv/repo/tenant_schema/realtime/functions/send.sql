create or replace function realtime.send (
  payload jsonb,
  event   text,
  topic   text,
  private boolean default true
)
  returns void
  language plpgsql
  AS $function$
DECLARE
  generated_id uuid;
  final_payload jsonb;
BEGIN
  BEGIN
    generated_id := gen_random_uuid();

    -- Add the generated UUID as 'id' to object payloads that don't have one
    IF jsonb_typeof(payload) <> 'object' OR payload ? 'id' THEN
      final_payload := payload;
    ELSE
      final_payload := jsonb_set(payload, '{id}', to_jsonb(generated_id));
    END IF;

    -- Set the topic configuration
    EXECUTE format('SET LOCAL realtime.topic TO %L', topic);

    INSERT INTO realtime.messages (id, payload, event, topic, private, extension)
    VALUES (generated_id, final_payload, event, topic, private, 'broadcast');
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'WarnSendingBroadcastMessage: %', SQLERRM;
  END;
END;
$function$;

alter function "realtime"."send"(jsonb, text, text, boolean) owner to "supabase_realtime_admin";
