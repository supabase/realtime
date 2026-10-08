import postgres from "postgres";
import { DB_URL, DB_SSL } from "./context.ts";

// postgres.js rather than Bun's built-in SQL: Bun's client always opens with a Postgres
// SSLRequest and ignores sslnegotiation=direct, so it can't reach SNI-routed gateways (e.g. the
// staging Envoy in front of db.<ref>.supabase.red) that expect a TLS ClientHello.
// Notices are dropped so `CREATE ... IF NOT EXISTS` chatter doesn't pollute --json stdout.
export const connectDb = () => postgres(DB_URL, { ssl: DB_SSL || false, onnotice: () => {} });

export type Db = ReturnType<typeof connectDb>;
