# Iterative Development Workflow

## Overview

This is your **day-to-day workflow** for implementing the music extension: implement a chunk → test it → iterate.

**How this differs from `DEVELOPMENT_WORKFLOW.md`:**
- **This doc:** Step-by-step workflow loop (what to do next)
- **That doc:** Reference guide (how to use tools, commands, debugging)

**Use this doc for:** "I just finished Phase 2.1, what's my next step?"  
**Use that doc for:** "How do I run tests?" or "How do I use IEx?"

---

## Quick Health Checks

**Frequent** (after code changes, ~10-30s):
```bash
mix compile && mix test test/extensions/music/ --max-failures 1 && mix credo --strict --format=flycheck && echo "✅" || echo "❌"
```

**Before commit** (~1-2min):
```bash
mix compile && mix test --max-failures 1 && mix format --check-formatted && mix credo --strict && echo "✅" || echo "❌"
```

---

## The Workflow Loop

```
1. Implement a subphase (from IMPLEMENTATION_PLAN.md)
   ↓
2. Run smoke tests (verify it works)
   ↓
3. Write/run unit tests (verify it's correct)
   ↓
4. Run linters (verify code quality)
   ↓
5. Commit (save progress)
   ↓
6. Repeat for next subphase
```

---

## Step-by-Step Workflow

### 1. Before Starting (Warm-Up)

**Run the warm-up checklist** (see `docs/WARMUP_CHECKLIST.md`):
```bash
# Verify environment is healthy
make dev_db          # Start databases
make seed            # Seed with test data
make dev             # Start server (in background or separate terminal)
```

**Verify baseline:**
```bash
# Run existing tests (should all pass)
mix test

# Check linters (should have minimal issues)
mix credo --strict
mix format --check-formatted
```

### 2. Implement a Subphase

**Example: Implementing Phase 2.1 (Tempo Server Core Logic)**

1. **Read the plan:**
   - Open `docs/IMPLEMENTATION_PLAN.md`
   - Find Phase 2.1
   - Review tasks, code samples, files to create/modify

2. **Create/modify files:**
   - Create `lib/extensions/music/tempo_server.ex`
   - Copy code samples from plan
   - Adapt to your needs

3. **Compile and check:**
   ```bash
   # Compile (catches syntax errors)
   mix compile
   
   # Check for warnings
   mix compile --warnings-as-errors
   ```

### 3. Run Smoke Tests

**Quick manual verification:**

```bash
# Start IEx console (if server not running)
iex -S mix

# Or if server is running, connect to it
# (if you started with `make dev`, IEx is already running)
```

```elixir
# In IEx, test your implementation
iex> # Test tempo server
iex> {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server("room-123", 120, "tenant-1")
iex> Realtime.Music.TempoServer.get_tempo("room-123", "tenant-1")
# Should return: {:ok, 120}
```

**Or use WebSocket client** (see `docs/TESTING_WITHOUT_FRONTEND.md`)

### 4. Write Unit Tests

**Reference test examples:**
- Open `docs/IMPLEMENTATION_TESTS.md`
- Find tests for your subphase (e.g., Phase 2.1)
- Copy/adapt test examples

**Create test file:**
```bash
# Create test file
touch test/extensions/music/tempo_server_test.exs
```

**Write tests:**
```elixir
defmodule Realtime.Music.TempoServerTest do
  use ExUnit.Case, async: true
  
  # Copy tests from IMPLEMENTATION_TESTS.md
  # Adapt as needed
end
```

**Run tests:**
```bash
# Run your new tests
mix test test/extensions/music/tempo_server_test.exs

# Run with watch mode (auto-rerun on changes)
mix test.watch test/extensions/music/tempo_server_test.exs
```

### 5. Run Linters

**Before committing:**
```bash
# Format code
mix format

# Check style
mix credo --strict

# Check types (if you have time)
mix dialyzer

# Security check
mix sobelow
```

**Fix issues:**
- Credo will suggest fixes
- Format will auto-fix formatting
- Dialyzer might need type annotations

### 6. Commit Progress

```bash
# Stage changes
git add lib/extensions/music/
git add test/extensions/music/

# Commit with descriptive message
git commit -m "Phase 2.1: Implement TempoServer core logic

- Add TempoServer GenServer with beat scheduling
- Store tenant_id in state for PubSub topics
- Implement get_tempo, set_tempo, start_clock, stop_clock
- Add tests for tempo operations"
```

### 7. Move to Next Subphase

**Repeat the loop:**
1. Read next subphase in plan
2. Implement
3. Smoke test
4. Write tests
5. Lint
6. Commit

---

## Quick Reference Commands

### Development
```bash
make dev_db          # Start databases
make seed            # Seed database
make dev             # Start server with IEx
mix compile          # Compile code
mix test             # Run all tests
mix test.watch       # Watch mode
```

### Testing
```bash
mix test test/extensions/music/tempo_server_test.exs  # Specific test
mix test --cover      # With coverage
mix test --trace      # Verbose output
```

### Linting
```bash
mix format            # Format code
mix credo             # Style check
mix dialyzer          # Type check
mix sobelow           # Security check
```

### Debugging
```elixir
# In IEx
iex> r Realtime.Music.TempoServer  # Reload module
iex> :observer.start()             # GUI process viewer
iex> Process.whereis(Module)       # Find process
```

---

## Common Workflow Patterns

### Pattern 1: TDD (Test-Driven Development)
```bash
1. Write test first (red)
2. Implement feature (green)
3. Refactor (improve)
```

### Pattern 2: Implement Then Test
```bash
1. Implement feature
2. Smoke test manually
3. Write tests
4. Refactor
```

### Pattern 3: Incremental (Recommended)
```bash
1. Implement minimal version
2. Smoke test
3. Add more features
4. Write tests
5. Refactor
```

---

## When Things Go Wrong

### Compilation Errors
```bash
# Clean and recompile
mix clean
mix compile
```

### Test Failures
```bash
# Run with verbose output
mix test --trace

# Run specific test
mix test test/extensions/music/tempo_server_test.exs:50

# Check test database
MIX_ENV=test mix ecto.reset
```

### Linter Errors
```bash
# Credo: Read suggestions, fix manually
mix credo --strict

# Format: Auto-fix
mix format

# Dialyzer: Check specific file
mix dialyzer lib/extensions/music/tempo_server.ex
```

### Server Won't Start
```bash
# Check if port is in use
lsof -i :4000

# Kill process
kill -9 <PID>

# Or use different port
PORT=4001 make dev
```

---

## Workflow Checklist (Per Subphase)

- [ ] Read subphase in `IMPLEMENTATION_PLAN.md`
- [ ] Create/modify files
- [ ] Compile (`mix compile`)
- [ ] Smoke test (IEx or WebSocket)
- [ ] Write tests (reference `IMPLEMENTATION_TESTS.md`)
- [ ] Run tests (`mix test`)
- [ ] Format code (`mix format`)
- [ ] Run linters (`mix credo`, `mix dialyzer`)
- [ ] Fix issues
- [ ] Commit changes
- [ ] Move to next subphase

---

## Time Estimates

**Per subphase:**
- Implementation: 30-60 minutes
- Smoke testing: 5-10 minutes
- Writing tests: 20-30 minutes
- Linting/fixing: 10-15 minutes
- **Total: ~1-2 hours per subphase**

**Per phase:**
- 2-4 subphases = 2-8 hours
- Matches the plan's day estimates

---

## Tips

1. **Start small:** Get one thing working, then add more
2. **Test frequently:** Don't wait until everything is done
3. **Commit often:** Small, focused commits are better
4. **Use watch mode:** `mix test.watch` saves time
5. **Keep IEx open:** Fast iteration for smoke tests
6. **Reference docs:** Keep `IMPLEMENTATION_PLAN.md` and `IMPLEMENTATION_TESTS.md` open

---

**Next:** Run the warm-up checklist to verify your environment is ready!

