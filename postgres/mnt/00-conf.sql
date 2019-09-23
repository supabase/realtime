ALTER SYSTEM SET wal_level='logical';
ALTER SYSTEM SET max_wal_senders='10';
ALTER SYSTEM SET max_replication_slots='10';


CREATE PUBLICATION supabase_realtime FOR ALL TABLES;

CREATE_REPLICATION_SLOT 'supabase_realtime_slot' LOGICAL pgoutput NOEXPORT_SNAPSHOT;