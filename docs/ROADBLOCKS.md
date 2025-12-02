# Implementation Roadblocks & Solutions

This document identifies potential roadblocks you might encounter while implementing the music extension, along with solutions and mitigation strategies.

---

## Critical Roadblocks (Must Solve)

### 1. Tempo Server Needs Tenant ID for PubSub Topics

**Problem:**
The tempo server only knows `room_id`, but PubSub topics require `tenant_id`. The topic format is:
```elixir
Tenants.tenant_topic(tenant_id, sub_topic, public?)
# => "tenant_id:music_room:room_id"
```

But tempo server only has `room_id` - it doesn't know which tenant the room belongs to.

**Why This Matters:**
- Tempo server broadcasts beats to PubSub
- Channels subscribe to tenant-scoped topics
- Without tenant_id, beats won't reach channels

**Solutions:**

**Option A: Store tenant_id in SessionManager (Recommended)**
```elixir
# In SessionManager, store tenant_id with room
room = %{
  room_id: room_id,
  tenant_id: tenant_id,  # Add this
  teacher_id: teacher_id,
  bpm: bpm,
  # ...
}

# Pass tenant_id when starting tempo server
def create_room(teacher_id, opts \\ []) do
  tenant_id = get_tenant_id_from_context()  # How to get this?
  # ...
  Realtime.Music.Supervisor.start_tempo_server(room_id, bpm, tenant_id)
end
```

**Option B: Pass tenant_id through channel to tempo server**
```elixir
# In MusicRoomChannel.join/3
def join("music_room:" <> room_id, params, socket) do
  tenant_id = socket.assigns.tenant  # Available in socket!
  
  # Start tempo server with tenant_id
  Realtime.Music.Supervisor.start_tempo_server(room_id, bpm, tenant_id)
  
  # Subscribe to correct topic
  tenant_topic = Tenants.tenant_topic(tenant_id, "music_room:#{room_id}", true)
  Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)
end
```

**Option C: Include tenant_id in room_id**
```elixir
# Generate room_id as "tenant_id:room_code"
room_id = "#{tenant_id}:MUSIC-1234"

# Then extract in tempo server
[tenant_id, room_code] = String.split(room_id, ":", parts: 2)
```

**Recommended Approach:** Option B - Get tenant_id from socket in channel, pass to tempo server, store in tempo server state.

**Implementation:**
```elixir
# lib/extensions/music/tempo_server.ex
def init({room_id, bpm, tenant_id}) do
  state = %{
    room_id: room_id,
    tenant_id: tenant_id,  # Store tenant_id
    bpm: bpm,
    # ...
  }
  {:ok, state}
end

def handle_info(:beat, state) do
  # Use tenant_id to construct topic
  tenant_topic = Tenants.tenant_topic(state.tenant_id, "music_room:#{state.room_id}", true)
  
  Phoenix.PubSub.broadcast(
    Realtime.PubSub,
    tenant_topic,
    {:beat, state.beat}
  )
  # ...
end
```

---

### 2. SessionManager Doesn't Know Tenant ID

**Problem:**
`SessionManager.create_room/2` is called without tenant context. But we need tenant_id to:
- Store with room state
- Pass to tempo server
- Query rooms by tenant (optional)

**Solutions:**

**Option A: Pass tenant_id as parameter**
```elixir
# In MusicRoomChannel or API endpoint
def create_room(teacher_id, tenant_id, opts \\ []) do
  SessionManager.create_room(teacher_id, tenant_id, opts)
end
```

**Option B: Store tenant_id in room_id (hacky)**
```elixir
# Include tenant_id in room_id format
room_id = "#{tenant_id}:MUSIC-1234"
```

**Option C: Use Process dictionary or ETS (not recommended)**
```elixir
# Store tenant_id in ETS before calling create_room
# Not recommended - breaks encapsulation
```

**Recommended Approach:** Option A - Always pass tenant_id explicitly.

**Implementation:**
```elixir
# lib/extensions/music/session_manager.ex
def create_room(teacher_id, tenant_id, opts \\ []) do
  GenServer.call(__MODULE__, {:create_room, teacher_id, tenant_id, opts})
end

def handle_call({:create_room, teacher_id, tenant_id, opts}, _from, state) do
  room_id = generate_join_code()
  bpm = Keyword.get(opts, :bpm, 120)
  
  room = %{
    room_id: room_id,
    tenant_id: tenant_id,  # Store tenant_id
    teacher_id: teacher_id,
    bpm: bpm,
    # ...
  }
  
  # Start tempo server with tenant_id
  Realtime.Music.Supervisor.start_tempo_server(room_id, bpm, tenant_id)
  
  {:reply, {:ok, room_id}, Map.put(state, room_id, room)}
end
```

---

### 3. Process Registry Key Collisions Across Tenants

**Problem:**
If two tenants create rooms with the same `room_id` (e.g., "MUSIC-1234"), the registry will have collisions:
```elixir
Registry.register(Realtime.Music.Registry, {:tempo_server, "MUSIC-1234"}, pid)
# Tenant A and Tenant B both use "MUSIC-1234" → collision!
```

**Solutions:**

**Option A: Include tenant_id in registry key (Recommended)**
```elixir
# Registry key format: {:tempo_server, tenant_id, room_id}
defp via_tuple(room_id, tenant_id) do
  {:via, Registry, {Realtime.Music.Registry, {:tempo_server, tenant_id, room_id}}}
end
```

**Option B: Make room_id globally unique**
```elixir
# Use UUID instead of "MUSIC-####"
room_id = UUID.uuid4()
# Or include tenant_id: room_id = "#{tenant_id}:MUSIC-1234"
```

**Option C: Separate registries per tenant (complex)**
```elixir
# Create registry per tenant - overkill
```

**Recommended Approach:** Option A - Include tenant_id in registry key.

**Implementation:**
```elixir
# lib/extensions/music/tempo_server.ex
def start_link({room_id, bpm, tenant_id}) do
  GenServer.start_link(
    __MODULE__,
    {room_id, bpm, tenant_id},
    name: via_tuple(room_id, tenant_id)
  )
end

defp via_tuple(room_id, tenant_id) do
  {:via, Registry, {Realtime.Music.Registry, {:tempo_server, tenant_id, room_id}}}
end

# Update all calls to include tenant_id
def get_tempo(room_id, tenant_id) do
  GenServer.call(via_tuple(room_id, tenant_id), :get_tempo)
end
```

---

## Significant Roadblocks (Should Solve)

### 4. Tempo Server Timing Drift

**Problem:**
`Process.send_after/3` is not perfectly accurate. Over time, beats will drift:
- 120 BPM = 500ms per beat
- After 100 beats (50 seconds), drift could be 50-100ms
- This causes tempo to feel "off" over long sessions

**Solutions:**

**Option A: Recalculate schedule on each beat (Recommended)**
```elixir
def handle_info(:beat, state) do
  # Broadcast beat
  # ...
  
  # Schedule next beat from current time (not from previous schedule)
  now = System.monotonic_time(:millisecond)
  next_beat_time = now + ms_per_beat(state.bpm)
  timer_ref = schedule_beat_at(next_beat_time)
  
  {:noreply, %{state | timer_ref: timer_ref}}
end

defp schedule_beat_at(target_time) do
  now = System.monotonic_time(:millisecond)
  delay = max(0, target_time - now)
  Process.send_after(self(), :beat, delay)
end
```

**Option B: Use Erlang timer module (more accurate)**
```elixir
:timer.send_interval(ms_per_beat, :beat)
```

**Option C: Accept drift (simplest)**
- For short sessions (< 5 minutes), drift is negligible
- Document that tempo may drift over long sessions

**Recommended Approach:** Option A - Recalculate schedule on each beat.

---

### 5. SessionManager State Lost on Restart

**Problem:**
`SessionManager` stores room state in GenServer state (in-memory). If the server restarts:
- All rooms are lost
- Tempo servers are lost
- Students can't reconnect

**Solutions:**

**Option A: Persist to database (Recommended for production)**
```elixir
# Store rooms in database
def create_room(teacher_id, tenant_id, opts) do
  # Insert into database
  %MusicRoom{}
  |> MusicRoom.changeset(%{room_id: room_id, teacher_id: teacher_id, ...})
  |> Repo.insert()
  
  # Then load from DB on startup
end

# On application start, load active rooms
def init(_) do
  rooms = Repo.all(from r in MusicRoom, where: r.active == true)
  state = Enum.reduce(rooms, %{}, fn room, acc ->
    Map.put(acc, room.room_id, room)
  end)
  {:ok, state}
end
```

**Option B: Accept ephemeral rooms (Simplest for MVP)**
- Rooms are temporary
- Teacher must recreate room after restart
- Document this limitation

**Option C: Use Mnesia or ETS with persistence**
```elixir
# Use ETS with disk_log for persistence
# More complex, but survives restarts
```

**Recommended Approach:** Option B for MVP, Option A for production.

---

### 6. Channel Topic vs PubSub Topic Mismatch

**Problem:**
Channel topic is `"music_room:ROOM_ID"`, but PubSub topic needs tenant prefix:
- Channel: `"music_room:MUSIC-1234"`
- PubSub: `"tenant_id:music_room:MUSIC-1234"`

If tempo server broadcasts to wrong topic, channels won't receive beats.

**Solution:**
Always use `Tenants.tenant_topic/3` to construct PubSub topics:

```elixir
# In tempo server
tenant_topic = Tenants.tenant_topic(tenant_id, "music_room:#{room_id}", true)

# In channel
tenant_topic = Tenants.tenant_topic(tenant_id, "music_room:#{room_id}", true)
Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)
```

**Verification:**
```elixir
# Test that topics match
channel_topic = "music_room:MUSIC-1234"
pubsub_topic = Tenants.tenant_topic("tenant-1", channel_topic, true)
# => "tenant-1:music_room:MUSIC-1234"

# Tempo server broadcasts to pubsub_topic
# Channel subscribes to pubsub_topic
# They match! ✅
```

---

## Moderate Roadblocks (Nice to Solve)

### 7. Testing Async Processes and Timing

**Problem:**
Testing tempo server beats requires waiting for async messages, which is flaky:
```elixir
assert_receive {:beat, _}, 600  # Might timeout or arrive early
```

**Solutions:**

**Option A: Use ExUnit async: false for timing tests**
```elixir
use ExUnit.Case, async: false  # Don't run in parallel
```

**Option B: Mock time or use test helpers**
```elixir
# Use Process.sleep with generous timeouts
assert_receive {:beat, _}, 1000  # More generous timeout
```

**Option C: Test timing logic separately**
```elixir
# Test that ms_per_beat calculation is correct
test "calculates beat interval correctly" do
  assert TempoServer.ms_per_beat(120) == 500
end

# Test that beats are scheduled (without waiting)
test "schedules next beat" do
  # Verify timer_ref is set
end
```

**Recommended Approach:** Option C - Test timing logic, not actual timing.

---

### 8. Rate Limiting with Music Events

**Problem:**
Music events (notes, beats) might hit rate limits:
- 20 students × 4 notes/second = 80 events/second
- Default limit might be 100 events/second
- Beats add another 2 events/second per room

**Solutions:**

**Option A: Increase rate limits for music tenants**
```elixir
# In tenant configuration
max_events_per_second: 200  # Higher limit for music
```

**Option B: Exempt beats from rate limiting**
```elixir
# Beats come from server, not clients
# Don't count them in rate limits
```

**Option C: Use separate rate limiters**
```elixir
# Different limits for music events vs. regular events
```

**Recommended Approach:** Option A - Configure higher limits for music tenants.

---

### 9. Memory Usage with Many Rooms

**Problem:**
Each room creates:
- 1 TempoServer GenServer (~2KB)
- 1 entry in SessionManager state (~200 bytes)
- Registry entries

With 1000 rooms = ~2MB just for processes (not including state).

**Solutions:**

**Option A: Accept memory usage (Recommended for MVP)**
- 1000 rooms = ~2MB (negligible)
- Elixir processes are lightweight

**Option B: Cleanup inactive rooms**
```elixir
# Periodically check for rooms with no students
# Close rooms inactive for > 1 hour
```

**Option C: Use database for room state**
```elixir
# Only keep active rooms in memory
# Load from DB on demand
```

**Recommended Approach:** Option A for MVP, Option B for production.

---

### 10. Authorization for Teacher Controls

**Problem:**
How do we verify a user is a teacher? Options:
- Check JWT claims (role: "teacher")
- Check database (user has teacher role)
- Trust client-sent role (insecure)

**Solutions:**

**Option A: Use JWT claims (Recommended)**
```elixir
# In channel join
def join("music_room:" <> room_id, params, socket) do
  claims = socket.assigns.claims  # From JWT
  role = claims["role"]
  
  socket = assign(socket, :role, role)
  # ...
end

# In teacher control handler
def handle_in("set_tempo", payload, socket) do
  if socket.assigns.role == "teacher" do
    # Allow
  else
    {:reply, {:error, %{reason: "unauthorized"}}, socket}
  end
end
```

**Option B: Check database (More secure)**
```elixir
# Query database to verify teacher role
# More secure but adds latency
```

**Option C: Use RLS policies (Most secure)**
```elixir
# Use PostgreSQL RLS to verify permissions
# Most secure but most complex
```

**Recommended Approach:** Option A for MVP, Option B for production.

---

## Minor Roadblocks (Can Work Around)

### 11. Join Code Collisions

**Problem:**
Random join codes might collide (unlikely but possible):
```elixir
"MUSIC-1234"  # Could be generated twice
```

**Solutions:**

**Option A: Check for duplicates (Recommended)**
```elixir
defp generate_join_code(state) do
  code = "MUSIC-#{:rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")}"
  
  if Map.has_key?(state, code) do
    generate_join_code(state)  # Retry
  else
    code
  end
end
```

**Option B: Use UUID (No collisions)**
```elixir
room_id = "MUSIC-#{UUID.uuid4() |> String.slice(0, 8)}"
```

**Option C: Accept collisions (Very unlikely)**
- 4 digits = 10,000 possible codes
- Collision probability is very low

**Recommended Approach:** Option A - Check for duplicates.

---

### 12. Tempo Server Cleanup on Room Close

**Problem:**
When room is closed, tempo server should stop. But if tempo server crashes, room state might be inconsistent.

**Solutions:**

**Option A: Supervisor handles crashes (Automatic)**
```elixir
# DynamicSupervisor automatically restarts crashed processes
# But we might want to stop tempo server when room closes
```

**Option B: Explicit cleanup**
```elixir
def close_room(room_id, tenant_id) do
  # Stop tempo server
  Realtime.Music.Supervisor.stop_tempo_server(room_id, tenant_id)
  
  # Remove from state
  # ...
end
```

**Option C: Let supervisor handle it**
```elixir
# If room is closed, tempo server will eventually timeout
# Supervisor will clean it up
```

**Recommended Approach:** Option B - Explicit cleanup.

---

### 13. Testing PubSub Broadcasts

**Problem:**
Testing that beats are broadcast correctly requires:
- Setting up PubSub subscription
- Waiting for messages
- Flaky timing

**Solutions:**

**Option A: Test PubSub directly**
```elixir
test "broadcasts beats to PubSub" do
  topic = "tenant-1:music_room:room-1"
  Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
  
  # Start tempo server
  # ...
  
  assert_receive {:beat, _}, 600
end
```

**Option B: Mock PubSub**
```elixir
# Use Mimic to mock Phoenix.PubSub.broadcast
# Verify it was called with correct arguments
```

**Option C: Integration tests only**
```elixir
# Only test PubSub in integration tests
# Unit tests test logic, not PubSub
```

**Recommended Approach:** Option A - Test PubSub directly in integration tests.

---

## Architectural Considerations

### 14. Should We Use Existing RealtimeChannel?

**Question:** Should we create `MusicRoomChannel` or extend `RealtimeChannel`?

**Option A: Create MusicRoomChannel (Recommended)**
**Pros:**
- Clean separation of concerns
- Music-specific logic isolated
- Easier to test

**Cons:**
- Duplicate some channel logic
- Need to maintain two channels

**Option B: Extend RealtimeChannel**
**Pros:**
- Reuse existing logic
- Less code duplication

**Cons:**
- Mixes concerns
- Harder to test
- More complex

**Recommended Approach:** Option A - Create separate channel for clarity.

---

### 15. Where to Store Room State?

**Question:** In-memory GenServer vs. database?

**Option A: In-memory (Recommended for MVP)**
- Fast
- Simple
- Lost on restart (acceptable for MVP)

**Option B: Database (Recommended for production)**
- Persists across restarts
- Can query rooms
- More complex

**Recommended Approach:** Option A for MVP, migrate to Option B for production.

---

## Performance Considerations

### 16. Tempo Server Accuracy Under Load

**Problem:**
Under high load, `Process.send_after/3` might be delayed, causing tempo drift.

**Mitigation:**
- Use `System.monotonic_time/1` for accurate timing
- Recalculate schedule on each beat
- Monitor tempo accuracy in production

### 17. PubSub Message Overhead

**Problem:**
Each beat creates a PubSub message. With 100 rooms × 2 beats/second = 200 messages/second.

**Mitigation:**
- Phoenix PubSub handles this easily (tested to 250k connections)
- Monitor message rates
- Consider batching if needed (unlikely)

---

## Testing Roadblocks

### 18. Testing Timing-Sensitive Code

**Problem:**
Tempo server timing is hard to test - requires waiting for real time to pass.

**Solutions:**
- Test timing logic (ms_per_beat calculation)
- Test that beats are scheduled (without waiting)
- Use integration tests for actual timing
- Accept some flakiness in timing tests

### 19. Testing Multi-Tenant Scenarios

**Problem:**
Testing that tenant isolation works correctly.

**Solutions:**
- Create multiple test tenants
- Verify rooms from different tenants don't interfere
- Test registry key collisions

---

## Deployment Roadblocks

### 20. Environment Variables

**Problem:**
Music extension might need new config (e.g., default BPM, max rooms).

**Solution:**
Add to `config/config.exs`:
```elixir
config :realtime, :music,
  default_bpm: 120,
  max_rooms_per_tenant: 100
```

### 21. Database Migrations

**Problem:**
If storing rooms in database, need migrations.

**Solution:**
Create migration:
```elixir
mix ecto.gen.migration create_music_rooms
```

---

## Summary: Critical Path

**Must Solve Before MVP:**
1. ✅ Tempo server tenant_id access (Roadblock #1)
2. ✅ SessionManager tenant_id (Roadblock #2)
3. ✅ Registry key collisions (Roadblock #3)
4. ✅ Channel/PubSub topic matching (Roadblock #6)

**Should Solve for Production:**
5. Tempo timing drift (Roadblock #4)
6. State persistence (Roadblock #5)
7. Authorization (Roadblock #10)

**Can Defer:**
- Everything else

---

## Quick Reference: Solutions

| Roadblock | Solution | Phase |
|-----------|----------|-------|
| Tempo server needs tenant_id | Pass from channel, store in state | Phase 2 |
| SessionManager tenant_id | Pass as parameter | Phase 4 |
| Registry collisions | Include tenant_id in key | Phase 1 |
| Timing drift | Recalculate on each beat | Phase 2 |
| State persistence | Database (later) | Phase 5 |
| Topic mismatch | Use Tenants.tenant_topic/3 | Phase 3 |

---

**Remember:** Most roadblocks have simple solutions. Focus on the critical path first, then iterate on improvements.

