SET client_min_messages TO WARNING;

CREATE SCHEMA IF NOT EXISTS realtime;

DROP TABLE IF EXISTS realtime.channels;
CREATE TABLE realtime.channels (
  id bigserial PRIMARY KEY,
  topic text NOT NULL,
  broadcast_storage_enabled_at timestamp,
  inserted_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
ALTER TABLE realtime.channels ADD CONSTRAINT channels_topic_index UNIQUE (topic);

DROP TABLE IF EXISTS realtime.messages_opt1;
CREATE TABLE realtime.messages_opt1 (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  topic text NOT NULL,
  extension text NOT NULL,
  payload jsonb,
  event text,
  private boolean DEFAULT false,
  inserted_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (id, inserted_at)
) PARTITION BY RANGE (inserted_at);

CREATE TABLE realtime.messages_opt1_today PARTITION OF realtime.messages_opt1
  FOR VALUES FROM (CURRENT_DATE) TO (CURRENT_DATE + 1);

CREATE INDEX ON realtime.messages_opt1 ((inserted_at) DESC, topic) WHERE extension = 'broadcast' AND private IS TRUE;

ALTER TABLE realtime.messages_opt1 ENABLE ROW LEVEL SECURITY;

DROP ROLE IF EXISTS bench_writer1;
CREATE ROLE bench_writer1 LOGIN PASSWORD 'postgres' NOSUPERUSER;
GRANT USAGE ON SCHEMA realtime TO bench_writer1;
GRANT SELECT ON realtime.channels TO bench_writer1;
GRANT INSERT, SELECT ON realtime.messages_opt1 TO bench_writer1;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA realtime TO bench_writer1;

CREATE POLICY bench_select ON realtime.messages_opt1 FOR SELECT TO bench_writer1 USING (true);
CREATE POLICY bench_insert_all ON realtime.messages_opt1 FOR INSERT TO bench_writer1 WITH CHECK (true);
