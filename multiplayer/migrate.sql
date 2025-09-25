CREATE OR REPLACE FUNCTION "public"."send_message_to_realtime"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    PERFORM realtime.send(
        jsonb_build_object(
            'id', new.id,
            'content', new.content,
            'username', new.username,
            'createdAt', to_char(new.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        'message',
        new.room,
        true
    );
    RETURN NEW;  -- Return the new row
END;$$;


ALTER FUNCTION "public"."send_message_to_realtime"() OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."new_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "content" "text" NOT NULL,
    "username" "text" NOT NULL,
    "room" "text" NOT NULL
);


ALTER TABLE "public"."new_messages" OWNER TO "postgres";


ALTER TABLE ONLY "public"."new_messages"
    ADD CONSTRAINT "new_messages_pkey" PRIMARY KEY ("id");



CREATE OR REPLACE TRIGGER "send_message_to_realtime" AFTER INSERT ON "public"."new_messages" FOR EACH ROW EXECUTE FUNCTION "public"."send_message_to_realtime"();



CREATE POLICY "Enable insert for anon users" ON "public"."new_messages" FOR INSERT TO "anon" WITH CHECK (true);


ALTER TABLE "public"."new_messages" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anon to listen for broadcast"
ON "realtime"."messages"
TO anon
using (true);

CREATE POLICY "Allow pushing broadcasts for anon users only"
ON "realtime"."messages"
TO anon
with CHECK (true);

