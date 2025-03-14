#!/bin/bash
set -euo pipefail
set -x
ulimit -n


echo "Testing database connection..."

# Use environment variables to construct connection string
POSTGRES_HOST=${DB_HOST}
POSTGRES_PORT=${DB_PORT}
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}

# Construct connection string
PG_CONN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}"

# Test connection and search_path
echo "Trying to connect to PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT} as ${POSTGRES_USER}..."
if psql "${PG_CONN}/${POSTGRES_DB}" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Database connection successful!"
    
    # Test search_path
    echo "Testing search_path setting..."
    psql "${PG_CONN}/${POSTGRES_DB}" -c "SET search_path TO _realtime; SELECT current_schema();" 
    
    # List available schemas
    echo "Available schemas:"
    psql "${PG_CONN}/${POSTGRES_DB}" -c "\dn"
    
    # Check if _realtime schema exists
    if psql "${PG_CONN}/${POSTGRES_DB}" -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = '_realtime';" | grep -q 1; then
        echo "✅ _realtime schema exists"
    else
        echo "❌ Warning: _realtime schema does not exist"
    fi
else
    echo "❌ Failed to connect to the database. Please check your credentials and network."
    echo "Error details:"
    psql "${PG_CONN}/${POSTGRES_DB}" -c "SELECT 1;"
    exit 1
fi


if [ ! -z "$RLIMIT_NOFILE" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi

export ERL_CRASH_DUMP=/tmp/erl_crash.dump

upload_crash_dump_to_s3() {
    EXIT_CODE=${?:-0}
    bucket=$ERL_CRASH_DUMP_S3_BUCKET
    s3Host=$ERL_CRASH_DUMP_S3_HOST
    s3Port=$ERL_CRASH_DUMP_S3_PORT

    if [ "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI-}" ]; then
        response=$(curl -s http://169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)
        s3Key=$(echo "$response" | grep -o '"AccessKeyId": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        s3Secret=$(echo "$response" | grep -o '"SecretAccessKey": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    else
        s3Key=$ERL_CRASH_DUMP_S3_KEY
        s3Secret=$ERL_CRASH_DUMP_S3_SECRET
    fi

    filePath=${ERL_CRASH_DUMP_FOLDER:-tmp}/$(date +%s)_${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump}

    if [ -f "${ERL_CRASH_DUMP_FOLDER:-tmp}/${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump}" ]; then
        mv ${ERL_CRASH_DUMP_FOLDER:-tmp}/${ERL_CRASH_DUMP_FILE_NAME:-erl_crash.dump} $filePath

        resource="/${bucket}/realtime/crash_dumps${filePath}"

        contentType="application/octet-stream"
        dateValue=$(date -R)
        stringToSign="PUT\n\n${contentType}\n${dateValue}\n${resource}"

        signature=$(echo -en ${stringToSign} | openssl sha1 -hmac ${s3Secret} -binary | base64)

        if [ "${ERL_CRASH_DUMP_S3_SSL:-}" = true ]; then
            protocol="https"
        else
            protocol="http"
        fi

        curl -v -X PUT -T "${filePath}" \
            -H "Host: ${s3Host}" \
            -H "Date: ${dateValue}" \
            -H "Content-Type: ${contentType}" \
            -H "Authorization: AWS ${s3Key}:${signature}" \
            ${protocol}://${s3Host}:${s3Port}${resource}
    fi

    exit "$EXIT_CODE"
}
if [ "${ENABLE_ERL_CRASH_DUMP:-false}" = true ]; then
    trap upload_crash_dump_to_s3 INT TERM KILL EXIT
fi


echo "Running migrations..."
if ! sudo -E -u nobody /app/bin/migrate; then
    echo "❌ Migration failed, exiting"
    # exit 1
fi
echo "✅ Migrations completed"

if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding selfhosted Realtime..."
    echo "Checking database connection..."
    if ! sudo -E -u nobody /app/bin/realtime eval 'IO.inspect(Realtime.Repo.query("SELECT 1"))'; then
        echo "❌ Database connection failed"
        # exit 1
    fi
    echo "Running seeding..."
    if ! sudo -E -u nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'; then
        echo "❌ Seeding failed"
        # exit 1
    fi
    echo "✅ Seeding completed"
fi

echo "Starting Realtime"
ulimit -n
exec "$@"