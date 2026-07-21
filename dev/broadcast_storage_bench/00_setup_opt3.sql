SET client_min_messages TO WARNING;

CREATE SCHEMA IF NOT EXISTS realtime;

DROP TABLE IF EXISTS realtime.messages_opt3;
CREATE TABLE realtime.messages_opt3 (
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

CREATE TABLE realtime.messages_opt3_today PARTITION OF realtime.messages_opt3
  FOR VALUES FROM (CURRENT_DATE) TO (CURRENT_DATE + 1);

CREATE INDEX ON realtime.messages_opt3 ((inserted_at) DESC, topic) WHERE extension = 'broadcast' AND private IS TRUE;

ALTER TABLE realtime.messages_opt3 ENABLE ROW LEVEL SECURITY;

DROP ROLE IF EXISTS bench_writer3;
CREATE ROLE bench_writer3 LOGIN PASSWORD 'postgres' NOSUPERUSER;
GRANT USAGE ON SCHEMA realtime TO bench_writer3;
GRANT INSERT, SELECT ON realtime.messages_opt3 TO bench_writer3;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA realtime TO bench_writer3;

CREATE POLICY bench_select3 ON realtime.messages_opt3 FOR SELECT TO bench_writer3 USING (true);
