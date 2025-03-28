#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Database connection parameters - use environment variables
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-postgres}
DB_USER=${DB_USER:-supabase_admin}
DB_PASSWORD=${DB_PASSWORD:-""}

# Function to run PostgreSQL queries and handle errors
run_query() {
    local query="$1"
    local result
    
    if [ -z "$DB_PASSWORD" ]; then
        result=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$query" 2>/dev/null)
    else
        result=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$query" 2>/dev/null)
    fi
    
    if [ $? -ne 0 ]; then
        echo "❌ Query failed: $query"
        return 1
    fi
    
    echo "$result"
}

# Safe function to run commands that might not be available
safe_cmd() {
    if command -v "$1" &> /dev/null; then
        "$@"
    else
        echo "N/A (command not found)"
    fi
}

# Get system metrics (safely)
load=$(safe_cmd uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | sed 's/^[ \t]*//' 2>/dev/null || echo "N/A")
mem_info=$(safe_cmd free -h | awk '/^Mem:/ {print $3 "/" $2}' 2>/dev/null || echo "N/A")
disk_usage=$(safe_cmd df -h / | awk 'NR==2 {print $5}' 2>/dev/null || echo "N/A")

# Container info (safely)
container_id=$(safe_cmd hostname || echo "unknown")
ip_address=$(safe_cmd hostname -I 2>/dev/null || echo "N/A")

# Check PostgreSQL connection
pg_status="⚠️ Not checked (no credentials)"
if [ -n "$DB_PASSWORD" ]; then
    pg_status=$(run_query "SELECT 1" >/dev/null && echo "${GREEN}✅ Connected${NC}" || echo "${RED}❌ Connection failed${NC}")

    # Only run these queries if DB connection succeeded
    if run_query "SELECT 1" >/dev/null; then
        # Get replication slot info
        replication_slot=$(run_query "SELECT slot_name, plugin, slot_type, database, 
                                    CASE WHEN active THEN '${GREEN}✅ Active${NC}' ELSE '${RED}❌ Inactive${NC}' END as active, 
                                    active_pid, confirmed_flush_lsn 
                                    FROM pg_replication_slots 
                                    WHERE slot_name LIKE '%realtime%';")

        # Check WAL retention
        wal_retention=$(run_query "SELECT slot_name, 
                                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as retained_wal,
                                CASE 
                                    WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) > 1073741824 THEN '${RED}High${NC}' 
                                    WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) > 104857600 THEN '${YELLOW}Medium${NC}' 
                                    ELSE '${GREEN}Low${NC}' 
                                END as retention_level
                                FROM pg_replication_slots
                                WHERE slot_name LIKE '%realtime%';")

        # Check tenants
        tenants=$(run_query "SELECT name, external_id FROM realtime.tenants LIMIT 5;")
    fi
fi

printf '%b\n' "\
+-----------------------------------------------------+
|    🔄 SUPABASE REALTIME - DIAGNOSTIC DASHBOARD 🔄    |
+-----------------------------------------------------+
| 💻 System:
|   🔄 Load Average     : $load
|   🧠 Memory Usage     : $mem_info
|   💾 Disk Usage       : $disk_usage
|   🖥️  Container ID     : $container_id
|   🌐 IP Address       : $ip_address
+-----------------------------------------------------+
| 🗄️  Database Connection: $pg_status
|   🌐 Host             : $DB_HOST:$DB_PORT
|   📊 Database         : $DB_NAME
"

# Only show DB-specific info if we have credentials and connection succeeded
if [ -n "$DB_PASSWORD" ] && run_query "SELECT 1" >/dev/null; then
printf '%b\n' "\
+-----------------------------------------------------+
| 👥 Tenants:
$(echo "$tenants" | sed 's/^/|   /')
+-----------------------------------------------------+
| 🔄 Replication Slot Status:
$(echo "$replication_slot" | sed 's/^/|   /')
+-----------------------------------------------------+
| 📝 WAL Retention:
$(echo "$wal_retention" | sed 's/^/|   /')
"
fi

printf '%b\n' "\
+-----------------------------------------------------+
| 🛠️  Common Commands:
|  psql "postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/postgres" 
|   🔍 Check tenant:
|     SELECT * FROM realtime.tenants;
|
|   🔄 Check replication slot:
|     SELECT slot_name, plugin, slot_type, database, active, 
|            active_pid, confirmed_flush_lsn 
|     FROM pg_replication_slots 
|     WHERE slot_name LIKE '%realtime%';
|
|   🔌 Start replication:
|     pg_recvlogical -h \$DB_HOST -p \$DB_PORT \\
|     -U \$DB_USER -d \$DB_NAME \\
|     --slot=supabase_realtime_rls --start \\
|     -o proto_version=1 \\
|     -o publication_names=mailopoly_publication -f -
|
|   📢 Create publication:
|     CREATE PUBLICATION mailopoly_publication 
|     FOR TABLE realtime.subscription;
|
|   🔄 Create replication slot:
|     SELECT pg_create_logical_replication_slot(
|       'supabase_realtime_rls', 'pgoutput');
+-----------------------------------------------------+"