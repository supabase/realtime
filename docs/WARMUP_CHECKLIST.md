# Warm-Up Checklist: Verify Healthy State

Run this checklist **before** starting implementation to ensure your environment is ready.

---

## Prerequisites Check

### 1. Verify Software Installed

```bash
# Check Elixir
elixir --version
# Should show: Elixir 1.18.x

# Check Erlang
erl -version
# Should show: Erlang/OTP 26+

# Check PostgreSQL
psql --version
# Should show: psql (PostgreSQL) 14.x

# Check Docker (if using)
docker --version
```

**If missing:** Install via asdf, homebrew, or your package manager.

---

## Environment Setup

### 2. Install Dependencies

```bash
# Install Elixir dependencies
mix deps.get

# Should complete without errors
# If errors: Check network, try again
```

**Expected output:**
```
* Getting realtime (deps/realtime)
* Getting phoenix (deps/phoenix)
...
```

### 3. Setup Database

```bash
# Start databases (Docker)
make dev_db

# Should show:
# Creating network...
# Starting containers...
# Running migrations...
```

**Verify databases are running:**
```bash
# Check containers
docker ps

# Should see:
# realtime-db (port 5432)
# tenant-db (port 5433)
```

**Or if using local PostgreSQL:**
```bash
# Create database
createdb realtime_dev

# Run migrations
mix ecto.migrate
```

### 4. Create _realtime Schema

The `_realtime` schema must exist before migrations run.

```bash
# Create schema (if Docker didn't create it)
psql -d postgres -h localhost -U postgres -c "CREATE SCHEMA IF NOT EXISTS _realtime;"

# Verify schema exists
psql -d postgres -h localhost -U postgres -c "\dn _realtime"
# Should show: _realtime schema
```

**Note:** Docker setup (`dev/postgres/00-supabase-schema.sql`) should create this, but if containers were recreated, it might be missing.

### 5. Run Migrations

**⚠️ IMPORTANT:** Migrations must run before seeding.

```bash
# Run migrations (creates tenants table in _realtime schema)
mix ecto.migrate

# Should show:
# [info] == Running Realtime.Repo.Migrations.CreateTenants.up/0 forward
# [info] == Migrated in X.Xs
```

**If migrations fail:**
```bash
# Reset and try again
mix ecto.reset
# This runs: drop, create, migrate
```

**Verify migrations worked:**
```bash
# Connect to database
psql -d postgres -h localhost -U postgres

# Check table exists in correct schema
\dt _realtime.tenants
# Should show: tenants table in _realtime schema
```

### 6. Seed Database

```bash
# Seed with default tenant
make seed

# Should complete without errors
```

**Verify seed worked:**
```bash
# Connect to database
psql -d postgres -h localhost -U postgres

# Check tenant exists
SELECT external_id FROM _realtime.tenants;
# Should show: realtime-dev (or similar)
```

---

## Compilation Check

### 7. Compile Project

```bash
# Clean and compile
mix clean
mix compile

# Should complete with:
# Compiled X files
# Generated realtime app
```

**If errors:**
- Check Elixir version matches `mix.exs` requirements
- Run `mix deps.get` again
- Check for missing system dependencies

---

## Test Suite Check

### 8. Run Existing Tests

```bash
# Run all tests
mix test

# Should pass (or have minimal known failures)
# Takes 1-2 minutes
```

**Expected:** All tests pass (or known failures only)

**If many failures:**
- Check database is running
- Check test database exists: `MIX_ENV=test mix ecto.create`
- Check environment variables

### 9. Run Specific Test Suite

```bash
# Test channels (core functionality)
mix test test/realtime_web/channels/realtime_channel_test.exs

# Should pass
```

---

## Server Check

### 10. Start Development Server

```bash
# Start server (in one terminal)
make dev

# Should show:
# [info] Running RealtimeWeb.Endpoint with cowboy 2.x
# [info] Access RealtimeWeb.Endpoint at http://localhost:4000
```

**Wait for:** Server to fully start (10-20 seconds)

### 11. Verify Server is Running

**In another terminal:**
```bash
# Option 1: Use /healthcheck endpoint (no tenant required)
curl http://localhost:4000/healthcheck
# Should return: ok

# Option 2: Use /api/ping with dev_tenant host header
curl -H "Host: dev_tenant" http://localhost:4000/api/ping
# Should return: {"message":"Success"}
```

**Note:** The `/api/ping` endpoint requires a tenant identified by the Host header. 
The seed script creates a tenant with `external_id: "dev_tenant"`, so you must 
use `Host: dev_tenant` header or access via `dev_tenant.localhost` if configured.

### 12. Check IEx Console

**If server started with `make dev`, IEx should be available:**

```elixir
# In IEx console (where server is running)
iex> Realtime.Supervisor
# Should return: Realtime.Supervisor (module, not error)

iex> Process.whereis(Realtime.Supervisor)
# Should return: #PID<...> (a process ID)

iex> Realtime.Tenants.Cache
# Should return: Realtime.Tenants.Cache (module)
```

---

## Linter Check

### 13. Check Code Formatting

```bash
# Check if code is formatted
mix format --check-formatted

# Should show: Format check passed
# Or list files that need formatting
```

**If files need formatting:**
```bash
# Auto-fix
mix format
```

### 14. Run Credo (Style Check)

```bash
# Run style checker
mix credo

# Should show minimal issues (or none)
# Focus on high-priority issues only
```

**Note:** Some existing code might have style issues - that's okay. Focus on new code.

### 15. Run Dialyzer (Type Check) - Optional

```bash
# First run takes 5-10 minutes (builds PLT)
mix dialyzer

# Subsequent runs are faster
# Should show minimal type errors
```

**Note:** Dialyzer can be slow. Skip for now if time-constrained.

---

## WebSocket Check

### 16. Test WebSocket Connection

**Using curl (if available):**
```bash
# Test WebSocket endpoint (basic check)
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: test" \
  http://localhost:4000/socket/websocket

# Should return HTTP 101 (Switching Protocols) or 400 (Bad Request)
# Either means server is responding
```

**Or use browser console:**
```javascript
// In browser console (on localhost:4000)
const ws = new WebSocket('ws://localhost:4000/socket/websocket?vsn=2.0.0')
ws.onopen = () => console.log('✅ WebSocket connected')
ws.onerror = (e) => console.log('❌ WebSocket error:', e)
```

---

## Quick Health Check Script

**Run this all at once:**

```bash
#!/bin/bash
# Quick health check

echo "1. Checking Elixir..."
elixir --version || echo "❌ Elixir not found"

echo "2. Checking dependencies..."
mix deps.get > /dev/null 2>&1 && echo "✅ Dependencies OK" || echo "❌ Dependencies failed"

echo "3. Running migrations..."
mix ecto.migrate > /dev/null 2>&1 && echo "✅ Migrations OK" || echo "❌ Migrations failed"

echo "4. Compiling..."
mix compile > /dev/null 2>&1 && echo "✅ Compilation OK" || echo "❌ Compilation failed"

echo "5. Running tests..."
mix test > /dev/null 2>&1 && echo "✅ Tests pass" || echo "⚠️  Some tests failed (check manually)"

echo "6. Checking server..."
curl -s http://localhost:4000/api/ping > /dev/null 2>&1 && echo "✅ Server running" || echo "⚠️  Server not running (start with 'make dev')"

echo "Done!"
```

**Save as `check_health.sh`, make executable, run:**
```bash
chmod +x check_health.sh
./check_health.sh
```

---

## Expected State

### ✅ Healthy State Looks Like:

- [x] Elixir 1.18+ installed
- [x] Dependencies installed (`mix deps.get` succeeds)
- [x] Databases running (Docker or local)
- [x] Database seeded (tenant exists)
- [x] Code compiles (`mix compile` succeeds)
- [x] Tests pass (`mix test` passes)
- [x] Server starts (`make dev` works)
- [x] Server responds (`curl http://localhost:4000/api/ping` returns `{"status":"ok"}`)
- [x] IEx console works (can run Elixir code)
- [x] Code is formatted (`mix format --check-formatted` passes)

### ⚠️ Acceptable Issues:

- Some Credo warnings (existing code)
- Dialyzer type warnings (if not blocking)
- Known test failures (documented)

### ❌ Blocking Issues (Fix Before Starting):

- Compilation errors
- Database connection failures
- Server won't start
- All tests failing

---

## If Something Fails

### Database Issues
```bash
# Reset databases
make stop
make dev_db

# Create _realtime schema if missing
psql -d postgres -h localhost -U postgres -c "CREATE SCHEMA IF NOT EXISTS _realtime;"

# Run migrations
mix ecto.migrate

# Seed
make seed
```

### Dependency Issues
```bash
# Clean and reinstall
mix deps.clean --all
mix deps.get
mix deps.compile
```

### Test Issues
```bash
# Reset test database
MIX_ENV=test mix ecto.reset
mix test
```

### Server Issues
```bash
# Check port
lsof -i :4000

# Kill process if needed
kill -9 <PID>

# Restart
make dev
```

---

## Ready to Start?

**Once all checks pass:**
1. ✅ Environment is healthy
2. ✅ You understand the workflow
3. ✅ You can test your changes
4. ✅ Ready to implement Phase 1!

**Next:** Start with Phase 0 (Setup) or Phase 1 (Extension Foundation) from `IMPLEMENTATION_PLAN.md`

---

## Quick Start Command

**Run this to verify everything:**
```bash
# One-liner health check (includes migrations)
mix deps.get && mix ecto.migrate && mix compile && mix test --max-failures 1 && echo "✅ Ready!" || echo "❌ Issues found"
```

