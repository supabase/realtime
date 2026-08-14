create schema "realtime" authorization "supabase_admin";

grant usage on schema "realtime" to "anon", "authenticated", "service_role";

revoke all on schema "realtime" from "supabase_realtime_admin";

grant create, usage on schema "realtime" to "supabase_realtime_admin" with grant option;
