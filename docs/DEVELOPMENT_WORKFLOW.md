# Development Workflow Guide

## Overview

This guide is a **reference manual** for working with Supabase Realtime: commands, tools, debugging, and how-tos.

**How this differs from `DEVELOPMENT_WORKFLOW_ITERATIVE.md`:**
- **This doc:** Reference guide (how to use tools, what commands do)
- **That doc:** Step-by-step workflow loop (what to do next, when to do it)

**Use this doc for:** "How do I run tests?" or "How do I use IEx?" or "What does this command do?"  
**Use that doc for:** "I just finished Phase 2.1, what's my next step?"

**Before starting:** Run the warm-up checklist in `docs/WARMUP_CHECKLIST.md` to verify your environment is healthy.

---

## Quick Reference

```bash
# Development
make dev             # Start dev server
make dev_db          # Start databases
make seed            # Seed database

# Testing
mix test             # Run all tests
mix test.watch       # Watch mode
mix test --cover     # With coverage

# Linting
mix credo            # Style check
mix dialyzer         # Type check
mix sobelow          # Security check

# Database
mix ecto.migrate     # Run migrations
mix ecto.rollback    # Rollback migration
mix ecto.reset       # Reset database

# Code Quality
mix format           # Format code
mix compile          # Compile project
mix deps.get         # Get dependencies
```

---

## Prerequisites

### Required Software
- **Elixir** (1.18+) - Install via [asdf](https://asdf-vm.com/) or [homebrew](https://brew.sh/)
- **PostgreSQL** (14+) - Install via homebrew or use Docker
- **Docker** (optional, but recommended) - For database containers
- **Node.js** (optional) - For frontend assets

### Verify Installation
```bash
# Check Elixir version
elixir --version
# Should show: Elixir 1.18.x

# Check Erlang version
erl -version
# Should show: Erlang/OTP 26+

# Check PostgreSQL
psql --version
# Should show: psql (PostgreSQL) 14.x

# Check Docker (if using)
docker --version
```

---

## Initial Setup

### 1. Clone and Install Dependencies

```bash
# Clone repository (if not already done)
git clone <your-fork-url>
cd realtime

# Install Elixir dependencies
mix deps.get

# Install Node.js dependencies (for assets)
cd assets && npm install && cd ..
```

### 2. Database Setup

**Option A: Using Docker (Recommended)**
```bash
# Start database containers
make dev_db

# This runs: docker-compose -f docker-compose.dbs.yml up -d
# Then: mix ecto.migrate --log-migrator-sql
```

**Option B: Local PostgreSQL**
```bash
# Create database
createdb realtime_dev

# Run migrations
mix ecto.migrate
```

### 3. Seed Database (Optional)

```bash
# Seed with default tenant
make seed

# Or manually:
DB_ENC_KEY="1234567890123456" mix run priv/repo/dev_seeds.exs
```

---

## Running the Server

### Development Server

**Using Makefile (Recommended)**
```bash
# Start dev server with IEx console
make dev

# This starts:
# - Phoenix server on http://localhost:4000
# - IEx console for interactive debugging
# - Code reloading enabled
# - Database connection pool
```

**Using Mix Directly**
```bash
# Start Phoenix server
mix phx.server

# Or with IEx console
iex -S mix phx.server
```

**Custom Port**
```bash
# Start on different port
PORT=4001 make dev
```

### Production-like Server

```bash
# Start with production environment
make prod

# This uses MIX_ENV=prod and production settings
```

### Multiple Nodes (Clustering)

```bash
# Start first node (pink)
make dev

# In another terminal, start second node (orange)
make dev.orange

# Nodes will automatically discover each other via EPMD
```

---

## Testing

### Running Tests

**All Tests**
```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/realtime_web/channels/realtime_channel_test.exs

# Run specific test
mix test test/realtime_web/channels/realtime_channel_test.exs:50
```

**Watch Mode (Auto-rerun on changes)**
```bash
# Install mix_test_watch (already in deps)
mix test.watch

# Or watch specific file
mix test.watch test/extensions/music/tempo_server_test.exs
```

**Parallel Testing**
```bash
# Tests run in parallel by default (max_cases: 4 in test_helper.exs)
# To change parallelism:
MIX_TEST_PARTITION=1 mix test  # Partition 1
MIX_TEST_PARTITION=2 mix test  # Partition 2
```

### Test Structure

**Test Files**
- Location: `test/`
- Naming: `*_test.exs`
- Structure: Mirror `lib/` structure

**Test Helpers**
- `test/support/channel_case.ex` - Channel testing utilities
- `test/support/containers.ex` - Docker container helpers
- `test/support/generators.ex` - Test data generators

**Example Test**
```elixir
defmodule RealtimeWeb.MusicRoomChannelTest do
  use RealtimeWeb.ChannelCase, async: true
  
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    {:ok, socket: socket, tenant: tenant}
  end
  
  test "student can join room", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(
      socket,
      "music_room:test-room",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    assert socket.assigns.student_id == "student-1"
  end
end
```

### Test Database

**Automatic Setup**
- Tests use `Ecto.Adapters.SQL.Sandbox` for isolation
- Each test gets its own database transaction
- Transactions are rolled back after each test

**Manual Database Access**
```bash
# Connect to test database
psql -d realtime_test

# Or via mix
mix ecto.reset  # Drops, creates, migrates test DB
```

---

## Linting & Code Quality

### Credo (Style & Best Practices)

**Run Credo**
```bash
# Check all files
mix credo

# Check specific file
mix credo lib/extensions/music/tempo_server.ex

# Show all issues (including low priority)
mix credo --all

# Show only high priority issues
mix credo --strict

# Auto-fix issues (where possible)
mix credo --strict --format flycheck
```

**Common Credo Issues**
- Unused variables
- Complex functions (cyclomatic complexity)
- Missing module docs
- Inconsistent naming

**Fix Example**
```elixir
# Before (Credo warning: unused variable)
def process(data, _unused_param) do
  data
end

# After (use underscore prefix for intentionally unused)
def process(data, _unused_param) do
  data
end
```

### Dialyzer (Static Analysis)

**Run Dialyzer**
```bash
# First run (builds PLT - takes 5-10 minutes)
mix dialyzer

# Subsequent runs (much faster)
mix dialyzer

# Check specific file
mix dialyzer lib/extensions/music/tempo_server.ex
```

**Dialyzer Checks**
- Type mismatches
- Unreachable code
- Function contract violations
- Missing function clauses

**Fix Example**
```elixir
# Before (Dialyzer warning: no return)
def get_tempo(room_id) when is_binary(room_id) do
  # Missing return
end

# After
def get_tempo(room_id) when is_binary(room_id) do
  GenServer.call(via_tuple(room_id), :get_tempo)
end
```

### Sobelow (Security)

**Run Sobelow**
```bash
# Check for security issues
mix sobelow

# Check specific directory
mix sobelow --root lib/extensions/music

# Verbose output
mix sobelow --verbose
```

**Common Sobelow Issues**
- SQL injection risks
- XSS vulnerabilities
- Insecure defaults

---

## Interactive Development (IEx)

### Starting IEx Console

**With Application Running**
```bash
# Start dev server (includes IEx)
make dev

# Or start IEx separately
iex -S mix
```

**Without Application**
```bash
# Start IEx with mix
iex -S mix

# Load specific module
iex> c "lib/extensions/music/tempo_server.ex"
```

### Useful IEx Commands

**Module Inspection**
```elixir
# Get module info
iex> h Realtime.Music.TempoServer

# Get function docs
iex> h Realtime.Music.TempoServer.get_tempo

# List module functions
iex> Realtime.Music.TempoServer.__info__(:functions)
```

**Process Inspection**
```elixir
# Find process by name
iex> Process.whereis(Realtime.Music.Supervisor)

# Get process info
iex> Process.info(pid)

# List all processes
iex> Process.list()

# Monitor a process
iex> Process.monitor(pid)
```

**Debugging**
```elixir
# Set breakpoint (requires :dbg)
iex> :dbg.tracer()
iex> :dbg.p(:all, :c)
iex> :dbg.tpl(Realtime.Music.TempoServer, :x)

# Inspect state
iex> :sys.get_state(pid)

# Get process tree
iex> :observer.start()
```

**Testing in IEx**
```elixir
# Run specific test
iex> ExUnit.run([test: "test/extensions/music/tempo_server_test.exs:50"])

# Run all tests
iex> ExUnit.run()
```

---

## Database Operations

### Migrations

**Create Migration**
```bash
# Create new migration
mix ecto.gen.migration create_music_rooms

# This creates: priv/repo/migrations/YYYYMMDDHHMMSS_create_music_rooms.exs
```

**Run Migrations**
```bash
# Run pending migrations
mix ecto.migrate

# Rollback last migration
mix ecto.rollback

# Rollback multiple
mix ecto.rollback --step 3

# Show migration status
mix ecto.migrations
```

**Migration Example**
```elixir
defmodule Realtime.Repo.Migrations.CreateMusicRooms do
  use Ecto.Migration

  def change do
    create table(:music_rooms, prefix: "realtime") do
      add :room_id, :string, null: false
      add :teacher_id, :string, null: false
      add :bpm, :integer, default: 120
      timestamps()
    end

    create unique_index(:music_rooms, [:room_id], prefix: "realtime")
  end
end
```

### Database Queries

**In IEx**
```elixir
# Query directly
iex> Realtime.Repo.all(Realtime.Api.Tenant)

# Insert record
iex> Realtime.Repo.insert(%Realtime.Api.Tenant{external_id: "test"})

# Update record
iex> tenant = Realtime.Repo.get!(Realtime.Api.Tenant, id)
iex> Realtime.Repo.update(Ecto.Changeset.change(tenant, name: "New Name"))
```

**Raw SQL**
```elixir
# Execute raw SQL
iex> Ecto.Adapters.SQL.query!(Realtime.Repo, "SELECT * FROM tenants LIMIT 1")
```

---

## Code Reloading

### Automatic Reloading

**Development Mode**
- Code automatically reloads when files change
- No need to restart server
- Changes take effect immediately

**Manual Reload**
```elixir
# In IEx, reload specific module
iex> r Realtime.Music.TempoServer

# Reload all modules
iex> recompile()
```

### When Reloading Doesn't Work

**Restart Required For:**
- Changes to `config/` files
- Changes to `mix.exs`
- Changes to supervisor tree
- Changes to application callbacks

**Restart Server**
```bash
# Stop server (Ctrl+C twice)
# Then restart
make dev
```

---

## Debugging

### Logger

**Log Levels**
```elixir
# In code
require Logger

Logger.debug("Debug message")
Logger.info("Info message")
Logger.warning("Warning message")
Logger.error("Error message")
```

**Set Log Level**
```elixir
# In IEx
Logger.configure(level: :debug)

# In config
config :logger, level: :debug
```

**Structured Logging**
```elixir
Logger.info("Music room created", 
  room_id: room_id, 
  teacher_id: teacher_id,
  bpm: bpm
)
```

### Process Monitoring

**Observer (GUI)**
```elixir
# Start observer
:observer.start()

# View:
# - Process tree
# - System info
# - Memory usage
# - ETS tables
```

**Recon (CLI)**
```elixir
# Get process info
:recon.info(pid)

# Get process memory
:recon.proc_count(:memory, 10)

# Get process message queue
:recon.proc_window(:message_queue_len, 10, :infinity)
```

### Tracing

**dbg (Debugger)**
```elixir
# Trace function calls
:dbg.tracer()
:dbg.p(:all, :c)
:dbg.tpl(Realtime.Music.TempoServer, :x)

# Call function
Realtime.Music.TempoServer.get_tempo("room-1")

# See trace output
```

---

## Common Tasks

### Adding a New Dependency

```bash
# Add to mix.exs
defp deps do
  [
    {:new_dependency, "~> 1.0"}
  ]
end

# Install
mix deps.get

# Compile
mix deps.compile
```

### Creating a New Module

```bash
# Create file manually
touch lib/extensions/music/new_module.ex

# Or use mix (if generator exists)
mix gen.module Realtime.Music.NewModule
```

### Formatting Code

```bash
# Format all files
mix format

# Format specific file
mix format lib/extensions/music/tempo_server.ex

# Check formatting (CI)
mix format --check-formatted
```

### Compiling

```bash
# Compile project
mix compile

# Force recompile
mix compile --force

# Clean build
mix clean
mix compile
```

---

## Docker Workflow

### Starting Services

```bash
# Start all services (db, realtime)
docker-compose up

# Start in background
docker-compose up -d

# Start specific service
docker-compose up db

# Start with specific file
docker-compose -f docker-compose.dbs.yml up
```

### Stopping Services

```bash
# Stop all services
docker-compose down

# Stop and remove volumes
docker-compose down -v

# Stop specific service
docker-compose stop db
```

### Viewing Logs

```bash
# All services
docker-compose logs

# Specific service
docker-compose logs realtime

# Follow logs
docker-compose logs -f realtime
```

### Rebuilding

```bash
# Rebuild images
docker-compose build

# Rebuild and restart
docker-compose up --build

# Rebuild specific service
docker-compose build realtime
```

---

## Performance Testing

### Benchmarking

```bash
# Run benchmark
make bench.secrets

# Or directly
mix run bench/gen_counter.exs
```

### Load Testing

**Using Apache Bench**
```bash
# Test HTTP endpoint
ab -n 1000 -c 10 http://localhost:4000/api/ping
```

**Using WebSocket Client**
```javascript
// Create multiple connections
for (let i = 0; i < 100; i++) {
  const channel = supabase.channel(`test-${i}`)
  channel.subscribe()
}
```

---

## CI/CD Workflow

### Pre-commit Checklist

```bash
# 1. Format code
mix format --check-formatted

# 2. Run linters
mix credo --strict
mix dialyzer
mix sobelow

# 3. Run tests
mix test --cover

# 4. Check for warnings
mix compile --warnings-as-errors
```

### Git Workflow

```bash
# Create feature branch
git checkout -b feature/music-extension

# Make changes
# ... edit files ...

# Stage changes
git add lib/extensions/music/

# Commit
git commit -m "Add music extension foundation"

# Push
git push origin feature/music-extension
```

---

## Troubleshooting

### Common Issues

**Port Already in Use**
```bash
# Find process using port
lsof -i :4000

# Kill process
kill -9 <PID>

# Or use different port
PORT=4001 make dev
```

**Database Connection Failed**
```bash
# Check PostgreSQL is running
pg_isready

# Check connection string
mix ecto.migrate --log-migrator-sql

# Reset database
mix ecto.reset
```

**Dependencies Out of Sync**
```bash
# Clean and reinstall
mix deps.clean --all
mix deps.get
mix deps.compile
```

**Tests Failing**
```bash
# Reset test database
MIX_ENV=test mix ecto.reset

# Run tests with verbose output
mix test --trace

# Run single test file
mix test test/extensions/music/tempo_server_test.exs
```

**Dialyzer Errors**
```bash
# Rebuild PLT
mix dialyzer --plt

# Or clean and rebuild
rm -rf priv/plts
mix dialyzer
```

---

## Useful Aliases

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
# Quick test run
alias mt="mix test"

# Quick format check
alias mf="mix format --check-formatted"

# Quick credo
alias mc="mix credo --strict"

# Quick compile
alias mcc="mix compile --force"

# Quick server restart
alias mdev="make dev"
```

---

## Resources

- **Elixir Docs**: https://hexdocs.pm/elixir/
- **Phoenix Docs**: https://hexdocs.pm/phoenix/
- **ExUnit Docs**: https://hexdocs.pm/ex_unit/
- **Credo Docs**: https://hexdocs.pm/credo/
- **Dialyzer Docs**: https://erlang.org/doc/man/dialyzer.html

---

This workflow guide should cover all your development needs. For specific issues, check the troubleshooting section or refer to the Elixir/Phoenix documentation.
