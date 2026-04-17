# Supabase Realtime JSONB Filter Limitation (MRE)

## Problem

Supabase Realtime `postgres_changes` filters only support direct column filters (e.g., `column=eq.value`). **JSONB expression filters are NOT supported**.

### Expected Behavior
When filtering on a JSONB field expression like `data->>organization_id`, events should be delivered to matching subscribers (like PostgREST filters).

### Actual Behavior
No events are received. The filter is silently ignored or rejected because Realtime does not evaluate SQL expressions.

## Setup Required

Before running the demo, you MUST apply the database migration.

Steps:
1. Open Supabase dashboard
2. Confirm the project URL matches the `[DEBUG] SUPABASE_URL` printed by the demo
3. Go to SQL Editor
4. Copy contents of migration.sql
5. Run it
6. Go to Project Settings → API → Exposed schemas and add `pgboss`

If not applied, you will see:

```text
[ERROR] Database schema not found
```

## Reproduction Steps

1. **Clone and setup:**
   ```bash
   npm install
   cp .env.example .env
   # Add SUPABASE_URL and SUPABASE_ANON_KEY
   ```

2. **Apply migration:**
   - Copy contents of `migration.sql`
   - Run in your Supabase SQL editor

3. **Run the demo:**
   ```bash
   npm start
   ```

4. **Expected output:**
   ```
   [SETUP] Supabase Realtime JSONB Filter MRE
   [SUBSCRIBED] Ready to receive events
   [INSERT] Creating job with JSONB data...
   [WAIT] Waiting 8s for realtime event...
   [subscription] event received: { ... }
   [RESULT] ✅ PASS: Realtime event received with direct column filter
   ```

See [expected-output.txt](expected-output.txt) for full example.

## Root Cause

Realtime does not evaluate or validate SQL expressions in filters. It only supports direct column equality:
- ✅ Supported: `column_name=eq.value`
- ❌ Not supported: `data->>'key'=eq.value`
- ❌ Not supported: `array_col[0]=eq.value`

This is by design because Supabase Realtime filters operate on logical replication (WAL) changes and do not evaluate SQL expressions like JSONB operators. Keeping the filter layer simple and performant is essential for scaling to thousands of concurrent subscriptions.

## Solution: Dedicated Column Pattern

Instead of filtering on JSONB expressions, mirror critical fields into dedicated scalar columns:

1. **Add column** – `organization_id TEXT`
2. **Backfill** – Extract from JSONB: `data->>'organization_id'`
3. **Sync with trigger** – Auto-update on INSERT/UPDATE
4. **Filter on column** – Use `organization_id=eq.value`
5. **Index** – Add for performance: `CREATE INDEX idx_job_organization_id`

### Files

- **migration.sql** – Creates schema, column, trigger, index, RLS policy
- **subscription-client.mjs** – Realtime subscription using correct filter
- **run-demo.mjs** – Demonstrates working filtered subscription
- **expected-output.txt** – Example successful run
- **package.json** – Dependencies

## Key Code Changes

### ❌ Broken (JSONB filter)
```javascript
.on('postgres_changes', {
  schema: 'pgboss',
  table: 'job',
  filter: 'data->>organization_id=eq.org_123'  // Does NOT work
})
```

### ✅ Fixed (direct column filter)
```javascript
.on('postgres_changes', {
  schema: 'pgboss',
  table: 'job',
  filter: 'organization_id=eq.org_123'  // Works!
})
```

### Database Trigger
```sql
create trigger sync_organization_id_trigger
before insert or update on pgboss.job
for each row
execute function sync_organization_id();
```

The trigger keeps `organization_id` in sync from JSONB on every write.

## Comparison

| Filter Type | PostgREST | Realtime | Reason |
|---|---|---|---|
| Direct column | ✅ Works | ✅ Works | Both support basic equality |
| JSONB operator | ✅ Works | ❌ Fails | Realtime doesn't evaluate SQL expressions |
| Array access | ✅ Works | ❌ Fails | Requires query evaluation |
| Function call | ✅ Works | ❌ Fails | Requires query evaluation |

**Why the difference?**
- **PostgREST**: Query-based API that evaluates full SQL expressions
- **Realtime**: Stream-based API that applies pattern matching on WAL replication events

## Conclusion

Supabase Realtime is a great real-time sync engine, but it's **not a query engine**. It only supports:
- Direct column filters
- Simple comparison operators (eq, neq, gt, gte, lt, lte, like, in)
- No SQL expressions or functions

For complex filtering on JSONB data, use the **dedicated column pattern** demonstrated here.

## Further Reading

- [Supabase Realtime Docs](https://supabase.com/docs/guides/realtime)
- [Realtime Filters Documentation](https://supabase.com/docs/guides/realtime#postgres_changes-schema)
- [PostgREST Filters](https://postgrest.org/en/stable/references/api/tables_views.html#operators)

