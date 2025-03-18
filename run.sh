#!/bin/bash

# Enable strict mode
set -euo pipefail
# Uncomment for debugging
# set -x

# Validate required environment variables
echo "Validating environment variables..."
for var in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD RLIMIT_NOFILE ERL_CRASH_DUMP_S3_BUCKET; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Error: Environment variable $var is not set or empty"
        exit 1
    fi
done
echo "✅ Environment variables validated"

# Database connection details
POSTGRES_HOST=${DB_HOST}
POSTGRES_PORT=${DB_PORT}
POSTGRES_DB=${DB_NAME}  # Typically 'postgres' for control plane
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}
PG_CONN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

# Test control database connection
echo "Testing control database connection..."
echo "Trying to connect to PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT} as ${POSTGRES_USER} (control db: ${POSTGRES_DB})..."
if psql "${PG_CONN}" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Control database connection successful!"
else
    echo "❌ Failed to connect to the control database. Please check your credentials and network."
    echo "Error details:"
    psql "${PG_CONN}" -c "SELECT 1;"
    exit 1
fi

# Check WAL and replication settings
echo "Checking PostgreSQL replication settings..."
WAL_LEVEL=$(psql "${PG_CONN}" -t -c "SHOW wal_level;" 2>/dev/null | tr -d ' ')
MAX_SLOTS=$(psql "${PG_CONN}" -t -c "SHOW max_replication_slots;" 2>/dev/null | tr -d ' ')
echo "wal_level: $WAL_LEVEL"
echo "max_replication_slots: $MAX_SLOTS"
if [ "$WAL_LEVEL" != "logical" ]; then
    echo "⚠️ Warning: wal_level is '$WAL_LEVEL', expected 'logical' for replication"
else
    echo "✅ wal_level is set to 'logical'"
fi
if [ "$MAX_SLOTS" -lt 1 ]; then
    echo "❌ Error: max_replication_slots is $MAX_SLOTS, must be >= 1"
    exit 1
else
    echo "✅ max_replication_slots is sufficient ($MAX_SLOTS)"
fi

# Check user replication privileges
echo "Checking replication privileges for ${POSTGRES_USER}..."
REPL_PRIV=$(psql "${PG_CONN}" -t -c "SELECT rolreplication FROM pg_roles WHERE rolname = '${POSTGRES_USER}';" 2>/dev/null | tr -d ' ')
if [ "$REPL_PRIV" = "t" ]; then
    echo "✅ ${POSTGRES_USER} has replication privileges"
else
    echo "⚠️ Warning: ${POSTGRES_USER} lacks replication privileges"
fi

# List tenants from control database
echo "Listing tenants from control database (${POSTGRES_DB}):"
TENANTS=$(psql "${PG_CONN}" -t -c "SELECT name, external_id FROM realtime.tenants;" 2>/dev/null)
echo "$TENANTS"
if [ -z "$TENANTS" ]; then
    echo "⚠️ Warning: No tenants found in realtime.tenants, proceeding with diagnostics"
    TENANT_DB="${POSTGRES_DB}"  # Fallback to control DB if no tenants
    EXTERNAL_ID="none"
else
    echo "✅ Tenants listed successfully"
    # Use first tenant
    EXTERNAL_ID=$(echo "$TENANTS" | head -n 1 | awk '{print $3}' | tr -d ' ')
    TENANT_NAME=$(echo "$TENANTS" | head -n 1 | awk '{print $1}' | tr -d ' ')
    TENANT_DB="${TENANT_NAME}"
    echo "Determined external_id from tenants table: ${EXTERNAL_ID}"
    echo "🏄 Introspected tenant database name: ${TENANT_DB}"
fi

# Construct tenant connection string
TENANT_PG_CONN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${TENANT_DB}"

# Test tenant database connection
echo "Testing tenant database connection (${TENANT_DB})..."
if psql "${TENANT_PG_CONN}" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Tenant database connection successful!"
else
    echo "❌ Warning: Failed to connect to tenant database (${TENANT_DB}). Using control DB for further diagnostics."
    echo "Error details:"
    psql "${TENANT_PG_CONN}" -c "SELECT 1;"
    TENANT_PG_CONN="${PG_CONN}"  # Fallback to control DB
fi

# Check realtime.subscription table
echo "Details of realtime.subscription table in database (${TENANT_DB}):"
SUBSCRIPTION_TABLE=$(psql "${TENANT_PG_CONN}" -c "\d realtime.subscription" 2>/dev/null)
echo "$SUBSCRIPTION_TABLE"
if echo "$SUBSCRIPTION_TABLE" | grep -q "subscription_id"; then
    echo "✅ realtime.subscription table found with expected structure"
else
    echo "⚠️ Warning: realtime.subscription table not found or missing expected structure"
fi

# List indexes on realtime.subscription
echo "Indexes on realtime.subscription:"
SUBSCRIPTION_INDEXES=$(psql "${TENANT_PG_CONN}" -t -c "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'realtime' AND tablename = 'subscription';" 2>/dev/null)
echo "$SUBSCRIPTION_INDEXES"
if [ -n "$SUBSCRIPTION_INDEXES" ]; then
    echo "✅ Indexes found on realtime.subscription"
else
    echo "⚠️ Warning: No indexes found on realtime.subscription"
fi

# List subscribed tables via publications
echo "Tables subscribed via publications in database (${TENANT_DB}):"
SUBSCRIBED_TABLES=$(psql "${TENANT_PG_CONN}" -t -c "SELECT pubname, schemaname, tablename FROM pg_publication_tables;" 2>/dev/null)
echo "$SUBSCRIBED_TABLES"
if [ -n "$SUBSCRIBED_TABLES" ]; then
    echo "✅ Subscribed tables found"
else
    echo "⚠️ Warning: No subscribed tables found in publications"
fi

# Check ownership of realtime.subscription
echo "Ownership of realtime.subscription:"
SUBSCRIPTION_OWNER=$(psql "${TENANT_PG_CONN}" -t -c "SELECT tableowner FROM pg_tables WHERE schemaname = 'realtime' AND tablename = 'subscription';" 2>/dev/null | tr -d '[:space:]')
echo "Owner: ${SUBSCRIPTION_OWNER:-unknown}"
if [ "$SUBSCRIPTION_OWNER" = "supabase_admin" ]; then
    echo "✅ realtime.subscription owned by supabase_admin"
else
    echo "⚠️ Warning: realtime.subscription owned by ${SUBSCRIPTION_OWNER:-unknown}, expected supabase_admin"
fi

# Check permissions on realtime.subscription
echo "Permissions on realtime.subscription:"
SUBSCRIPTION_PERMS=$(psql "${TENANT_PG_CONN}" -t -c "\dp realtime.subscription" 2>/dev/null)
echo "$SUBSCRIPTION_PERMS"
if echo "$SUBSCRIPTION_PERMS" | grep -q "supabase_admin"; then
    echo "✅ Permissions include supabase_admin"
else
    echo "⚠️ Warning: supabase_admin lacks permissions on realtime.subscription"
fi

# List current subscriptions
echo "Current subscriptions in realtime.subscription:"
CURRENT_SUBS=$(psql "${TENANT_PG_CONN}" -t -c "SELECT subscription_id, entity FROM realtime.subscription;" 2>/dev/null)
echo "$CURRENT_SUBS"
if [ -n "$CURRENT_SUBS" ]; then
    echo "✅ Active subscriptions found"
else
    echo "⚠️ Warning: No active subscriptions found"
fi

# List replication slots
echo "Replication slots in database (${TENANT_DB}):"
REPLICATION_SLOTS=$(psql "${TENANT_PG_CONN}" -t -c "SELECT slot_name, plugin, slot_type, database, active, confirmed_flush_lsn FROM pg_replication_slots;" 2>/dev/null)
echo "$REPLICATION_SLOTS"
if [ -n "$REPLICATION_SLOTS" ]; then
    echo "✅ Replication slots found"
    # Check for expected slot
    if echo "$REPLICATION_SLOTS" | grep -q "supabase_realtime_rls"; then
        SLOT_ACTIVE=$(echo "$REPLICATION_SLOTS" | grep "supabase_realtime_rls" | awk '{print $5}')
        if [ "$SLOT_ACTIVE" = "t" ]; then
            echo "✅ supabase_realtime_rls slot is active"
        else
            echo "⚠️ Warning: supabase_realtime_rls slot exists but is inactive"
        fi
    else
        echo "⚠️ Warning: supabase_realtime_rls slot not found"
    fi
else
    echo "⚠️ Warning: No replication slots found"
fi

# Test publication status
echo "Checking publication status in database (${TENANT_DB}):"
PUBLICATIONS=$(psql "${TENANT_PG_CONN}" -t -c "SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication;" 2>/dev/null)
echo "$PUBLICATIONS"
if echo "$PUBLICATIONS" | grep -q "mailopoly_publication"; then
    echo "✅ mailopoly_publication found"
else
    echo "⚠️ Warning: mailopoly_publication not found"
fi

# Test search_path (control db)
echo "Testing search_path setting (control db)..."
SEARCH_PATH_RESULT=$(psql "${PG_CONN}" -t -c "SET search_path TO _realtime; SELECT current_schema();" 2>/dev/null)
if echo "$SEARCH_PATH_RESULT" | grep -q "_realtime"; then
    echo "✅ Search path set to _realtime successfully (control db)"
else
    echo "⚠️ Warning: Failed to set search_path to _realtime. Current schema: $(echo "$SEARCH_PATH_RESULT" | tail -n 1)"
fi

# List available schemas (control db)
echo "Available schemas (control db):"
SCHEMA_LIST=$(psql "${PG_CONN}" -t -c "\dn" 2>/dev/null)
echo "$SCHEMA_LIST"
if echo "$SCHEMA_LIST" | grep -q "_realtime"; then
    echo "✅ _realtime schema found (control db)"
else
    echo "❌ Warning: _realtime schema not found in the list (control db)"
fi

# Check _realtime schema ownership (control db)
if psql "${PG_CONN}" -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = '_realtime';" | grep -q 1; then
    echo "✅ _realtime schema exists (control db)"
    OWNER=$(psql "${PG_CONN}" -t -c "SELECT nspowner::regrole FROM pg_namespace WHERE nspname = '_realtime';" | tr -d '[:space:]')
    if [ "$OWNER" = "supabase_admin" ]; then
        echo "✅ _realtime schema owned by supabase_admin (control db)"
    else
        echo "⚠️ Warning: _realtime schema owned by $OWNER, expected supabase_admin (control db)"
    fi
else
    echo "❌ Warning: _realtime schema does not exist (control db)"
fi

# Check realtime schema (control db)
if psql "${PG_CONN}" -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'realtime';" | grep -q 1; then
    echo "✅ realtime schema exists (control db)"
else
    echo "⚠️ Warning: realtime schema does not exist (control db)"
fi

# Set RLIMIT_NOFILE
if [ -n "$RLIMIT_NOFILE" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    if ! ulimit -Sn "$RLIMIT_NOFILE" 2>/dev/null; then
        echo "❌ Error: Failed to set RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
        exit 1
    fi
    echo "✅ RLIMIT_NOFILE set to ${RLIMIT_NOFILE}"
fi

# Crash dump handling
export ERL_CRASH_DUMP=/tmp/erl_crash.dump

upload_crash_dump_to_s3() {
    EXIT_CODE=${?:-0}
    bucket=$ERL_CRASH_DUMP_S3_BUCKET
    s3Host=$ERL_CRASH_DUMP_S3_HOST
    s3Port=$ERL_CRASH_DUMP_S3_PORT

    if [ -z "$bucket" ]; then
        echo "⚠️ Warning: ERL_CRASH_DUMP_S3_BUCKET not set, skipping crash dump upload"
        return
    fi

    if [ "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI-}" ]; then
        response=$(curl -s http://169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)
        s3Key=$(echo "$response" | grep -o '"AccessKeyId": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        s3Secret=$(echo "$response" | grep -o '"SecretAccessKey": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    else
        s3Key=$ERL_CRASH_DUMP_S3_KEY
        s3Secret=$ERL_CRASH_DUMP_S3_SECRET
    fi

    if [ -z "$s3Key" ] || [ -z "$s3Secret" ]; then
        echo "❌ Error: S3 credentials not found"
        return
    fi

    filePath=${ERL_CRASH_DUMP_FOLDER:-tmp}/$(date +%s)_${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump}
    if [ -f "${ERL_CRASH_DUMP_FOLDER:-tmp}/${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump}" ]; then
        mv "${ERL_CRASH_DUMP_FOLDER:-tmp}/${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump}" "$filePath"
        resource="/${bucket}/realtime/crash_dumps${filePath}"
        contentType="application/octet-stream"
        dateValue=$(date -R)
        stringToSign="PUT\n\n${contentType}\n${dateValue}\n${resource}"
        signature=$(echo -en "${stringToSign}" | openssl sha1 -hmac "${s3Secret}" -binary | base64)

        if [ "${ERL_CRASH_DUMP_S3_SSL:-}" = true ]; then
            protocol="https"
        else
            protocol="http"
        fi

        if ! curl -v -X PUT -T "${filePath}" \
            -H "Host: ${s3Host}" \
            -H "Date: ${dateValue}" \
            -H "Content-Type: ${contentType}" \
            -H "Authorization: AWS ${s3Key}:${signature}" \
            "${protocol}://${s3Host}:${s3Port}${resource}" > /dev/null 2>&1; then
            echo "❌ Error: Failed to upload crash dump to S3"
        else
            echo "✅ Crash dump uploaded to S3 at ${resource}"
        fi
    fi
    exit "$EXIT_CODE"
}

if [ "${ENABLE_ERL_CRASH_DUMP:-false}" = true ]; then
    trap upload_crash_dump_to_s3 INT TERM KILL EXIT
fi

# Run migrations
echo "Running migrations..."
if ! sudo -E -u nobody /app/bin/migrate --log-level debug; then
    echo "❌ Migration failed"
    MIGRATION_STATUS=$(psql "${PG_CONN}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'realtime' AND table_name = 'schema_migrations';" 2>/dev/null)
    if [ "$MIGRATION_STATUS" -eq 0 ]; then
        echo "❌ Warning: schema_migrations table not found, migrations may not have started"
    else
        echo "⚠️ Warning: Migration failed but schema_migrations table exists, check for partial application"
    fi
    psql "${PG_CONN}" -c "\dt realtime.*"
else
    echo "✅ Migrations completed"
fi

# Verify key tables
echo "Verifying key tables..."
for table in tenants schema_migrations; do
    if psql "${PG_CONN}" -t -c "SELECT 1 FROM information_schema.tables WHERE table_schema = 'realtime' AND table_name = '$table' LIMIT 1;" | grep -q 1; then
        echo "✅ $table table exists in realtime schema"
    else
        echo "❌ Warning: $table table not found in realtime schema"
    fi
done

# Seed if enabled
if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding self-hosted Realtime..."
    if ! sudo -E -u nobody /app/bin/realtime eval 'IO.inspect(Realtime.Repo.query("SELECT 1"))' > /dev/null 2>&1; then
        echo "❌ Database connection failed for seeding"
    else
        echo "✅ Database connection for seeding successful"
        if ! sudo -E -u nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)' > /dev/null 2>&1; then
            echo "❌ Seeding failed"
        else
            echo "✅ Seeding completed"
        fi
    fi
fi

echo "Starting Realtime with external_id: ${EXTERNAL_ID}"
ulimit -n
sleep 15  # Delay for logs
exec "$@"
