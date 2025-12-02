# Music Extension Implementation Plan

## Overview

This plan breaks down the music education extension into granular phases and subphases, each with specific tasks, code samples, files to modify, and smoke tests.

**Goal:** Add real-time collaborative music features to Supabase Realtime:
- Music room channels
- Tempo clock server
- Teacher controls (tempo, muting, role assignment)
- Session management (join codes, room creation)
- SEL data integration (optional, Phase 6)

**What You're Building:** A real-time WebSocket API that a frontend will consume. You can test ~80% of functionality without building a custom frontend - see `docs/TESTING_WITHOUT_FRONTEND.md` for how to test each phase using IEx, WebSocket clients, and integration tests.

**Note:** 
- High-value unit test examples are in `docs/IMPLEMENTATION_TESTS.md` - reference them by phase/subphase as you implement.
- **⚠️ CRITICAL:** See `docs/ROADBLOCKS.md` for potential issues and solutions before starting implementation.

---

## Phase 0: Setup & Foundation (Day 1)

### Goal
Set up development environment and understand the codebase structure.

### Subphase 0.1: Environment Setup

#### Tasks
- [ ] Install Elixir (via asdf or homebrew)
- [ ] Install PostgreSQL (if not using Docker)
- [ ] Clone and explore codebase structure
- [ ] Run existing tests to verify setup

#### Verification
```bash
# Check Elixir version
elixir --version  # Should show 1.18+

# Check PostgreSQL
psql --version    # Should show 14+

# Install dependencies
mix deps.get

# Run tests
mix test          # Should pass all existing tests
```

### Subphase 0.2: Codebase Exploration

#### Tasks
- [ ] Read `lib/realtime/application.ex` (supervisor tree)
- [ ] Read `lib/realtime_web/channels/realtime_channel.ex` (channel logic)
- [ ] Read `lib/extensions/postgres_cdc_rls/` (example extension)
- [ ] Understand tenant system (`lib/realtime/tenants/`)

#### Key Files to Review
- `lib/realtime/application.ex` - Application startup, supervisor tree
- `lib/realtime_web/channels/realtime_channel.ex` - Channel join/broadcast logic
- `lib/extensions/postgres_cdc_rls/supervisor.ex` - Extension supervisor pattern
- `config/config.exs` - Extension registration

### Subphase 0.3: Development Workflow Setup

#### Tasks
- [ ] Set up database: `make dev_db`
- [ ] Start dev server: `make dev`
- [ ] Run tests: `mix test`
- [ ] Run linters: `mix credo`, `mix dialyzer`, `mix sobelow`

#### Smoke Test
```bash
# Start dev server
make dev

# In another terminal, verify server is running
curl http://localhost:4000/api/ping
# Expected: {"status": "ok"}
```

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 0**

---

## Phase 1: Music Extension Foundation (Day 2-3)

### Goal
Create the basic extension structure and register it with the application.

### Subphase 1.1: Create Extension Directory Structure

#### Tasks
- [ ] Create `lib/extensions/music/` directory
- [ ] Create `lib/extensions/music/supervisor.ex`
- [ ] Create `lib/extensions/music/registry.ex` (for process registry)

#### Files to Create

**`lib/extensions/music/registry.ex`**
```elixir
defmodule Realtime.Music.Registry do
  @moduledoc """
  Registry for music extension processes.
  Used to look up tempo servers and other music processes by room_id.
  """
  use Registry, keys: :unique, name: __MODULE__
end
```

**`lib/extensions/music/supervisor.ex`**
```elixir
defmodule Realtime.Music.Supervisor do
  @moduledoc """
  DynamicSupervisor for music extension processes.
  Manages tempo servers and other music-related GenServers.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(
      name: __MODULE__,
      strategy: :one_for_one
    )
  end

  # Placeholder - will be implemented in Phase 2
  def start_tempo_server(_room_id, _bpm \\ 120) do
    {:error, :not_implemented}
  end
end
```

#### Smoke Test
```elixir
# In IEx console (started with `make dev`)
iex> Realtime.Music.Supervisor
# Should return the module, not an error

iex> DynamicSupervisor.which_children(Realtime.Music.Supervisor)
# Should return empty list (no children yet, but supervisor is running)
```

### Subphase 1.2: Register Extension

#### Tasks
- [ ] Add music extension to `config/config.exs`
- [ ] Verify extension supervisor starts in `lib/realtime/application.ex`

#### Files to Modify

**`config/config.exs`** - Add to existing extensions config:
```elixir
config :realtime, :extensions,
  postgres_cdc_rls: %{
    supervisor: Extensions.PostgresCdcRls.Supervisor,
    key: "postgres_cdc_rls",
    db_settings: Extensions.PostgresCdcRls.DBSettings
  },
  # Add this:
  music: %{
    supervisor: Realtime.Music.Supervisor,
    key: "music"
  }
```

**Note:** `lib/realtime/application.ex` automatically starts extensions via `extensions_supervisors/0` - no changes needed!

#### Verification
```elixir
# In IEx, verify supervisor is running
iex> Process.whereis(Realtime.Music.Supervisor)
# Should return a PID, not nil
```

### Subphase 1.3: Create Basic Module Structure

#### Tasks
- [ ] Create `lib/extensions/music/tempo_server.ex` (skeleton)
- [ ] Create `lib/extensions/music/session_manager.ex` (skeleton)

#### Files to Create

**`lib/extensions/music/tempo_server.ex`** (Skeleton)
```elixir
defmodule Realtime.Music.TempoServer do
  @moduledoc """
  GenServer that maintains a tempo clock and broadcasts beat events.
  
  Each music room has its own TempoServer process.
  The server sends beat events at the specified BPM to all clients in the room.
  """
  use GenServer
  require Logger

  ## Client API (to be implemented in Phase 2)
  
  @doc """
  Start a tempo server for a room.
  """
  def start_link({room_id, bpm}) do
    GenServer.start_link(__MODULE__, {room_id, bpm}, name: via_tuple(room_id))
  end

  @doc """
  Get current tempo for a room.
  """
  def get_tempo(room_id) do
    GenServer.call(via_tuple(room_id), :get_tempo)
  end

  ## Server Callbacks (to be implemented in Phase 2)
  
  @impl true
  def init({room_id, bpm}) do
    Logger.info("Starting tempo server for room #{room_id} at #{bpm} BPM")
    {:ok, %{room_id: room_id, bpm: bpm, beat: 0, running: false, timer_ref: nil}}
  end

  @impl true
  def handle_call(:get_tempo, _from, state) do
    {:reply, {:ok, state.bpm}, state}
  end

  ## Private Functions
  
  defp via_tuple(room_id) do
    {:via, Registry, {Realtime.Music.Registry, {:tempo_server, room_id}}}
  end
end
```

**`lib/extensions/music/session_manager.ex`** (Skeleton)
```elixir
defmodule Realtime.Music.SessionManager do
  @moduledoc """
  Manages music room sessions.
  
  Handles:
  - Room creation
  - Join code generation
  - Room state tracking
  - Room cleanup
  """
  use GenServer

  ## Client API (to be implemented in Phase 4)
  
  @doc """
  Create a new music room.
  """
  def create_room(teacher_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create_room, teacher_id, opts})
  end

  @doc """
  Get room information.
  """
  def get_room(room_id) do
    GenServer.call(__MODULE__, {:get_room, room_id})
  end

  ## Server Callbacks (to be implemented in Phase 4)
  
  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_room, _teacher_id, _opts}, _from, state) do
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:get_room, _room_id}, _from, state) do
    {:reply, {:error, :not_implemented}, state}
  end
end
```

**`lib/realtime/application.ex`** - Add SessionManager to children:
```elixir
children =
  [
    # ... existing children ...
    RealtimeWeb.Endpoint,
    RealtimeWeb.Presence
  ] ++ extensions_supervisors() ++ janitor_tasks() ++ [
    # Add this:
    Realtime.Music.SessionManager
  ]
```

#### Smoke Test
```elixir
# In IEx console
iex> Realtime.Music.TempoServer
# Should return module, not error

iex> Realtime.Music.SessionManager
# Should return module, not error

iex> Process.whereis(Realtime.Music.SessionManager)
# Should return PID (process is running)
```

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 1**

---

## Phase 2: Tempo Server (Day 4-5)

### Goal
Implement a GenServer that broadcasts beat events at a given BPM.

### Subphase 2.1: Implement Core TempoServer Logic

#### Tasks
- [ ] Implement `init/1` (schedules first beat)
- [ ] Implement `handle_info(:beat, state)` (broadcasts beat, schedules next)
- [ ] Implement beat scheduling logic

#### Files to Modify

**`lib/extensions/music/tempo_server.ex`** - Complete implementation:

**⚠️ CRITICAL:** See `docs/ROADBLOCKS.md` #1 - Tempo server needs tenant_id for PubSub topics.

```elixir
defmodule Realtime.Music.TempoServer do
  use GenServer
  require Logger

  alias Realtime.Music.Supervisor
  alias Realtime.Tenants

  ## Client API
  
  # ⚠️ Note: tenant_id is required for PubSub topic construction
  def start_link({room_id, bpm, tenant_id}) do
    GenServer.start_link(__MODULE__, {room_id, bpm, tenant_id}, name: via_tuple(room_id, tenant_id))
  end

  # ⚠️ All functions now require tenant_id (see Roadblock #1, #3)
  def get_tempo(room_id, tenant_id) do
    GenServer.call(via_tuple(room_id, tenant_id), :get_tempo)
  end

  def set_tempo(room_id, tenant_id, bpm) when bpm > 0 and bpm < 300 do
    GenServer.cast(via_tuple(room_id, tenant_id), {:set_tempo, bpm})
  end

  def start_clock(room_id, tenant_id) do
    GenServer.cast(via_tuple(room_id, tenant_id), :start_clock)
  end

  def stop_clock(room_id, tenant_id) do
    GenServer.cast(via_tuple(room_id, tenant_id), :stop_clock)
  end

  ## Server Callbacks
  
  @impl true
  def init({room_id, bpm, tenant_id}) do
    Logger.info("Starting tempo server for room #{room_id} (tenant: #{tenant_id}) at #{bpm} BPM")
    
    state = %{
      room_id: room_id,
      tenant_id: tenant_id,  # ⚠️ Store tenant_id for PubSub topics
      bpm: bpm,
      beat: 0,
      running: false,
      timer_ref: nil
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call(:get_tempo, _from, state) do
    {:reply, {:ok, state.bpm}, state}
  end

  @impl true
  def handle_cast({:set_tempo, bpm}, state) do
    Logger.info("Setting tempo to #{bpm} BPM for room #{state.room_id}")
    
    # Cancel existing timer if running
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    # Schedule next beat with new tempo if running
    new_timer_ref = if state.running do
      schedule_beat(bpm)
    else
      nil
    end
    
    {:noreply, %{state | bpm: bpm, timer_ref: new_timer_ref}}
  end

  @impl true
  def handle_cast(:start_clock, state) do
    Logger.info("Starting clock for room #{state.room_id}")
    
    timer_ref = schedule_beat(state.bpm)
    
    {:noreply, %{state | running: true, timer_ref: timer_ref, beat: 0}}
  end

  @impl true
  def handle_cast(:stop_clock, state) do
    Logger.info("Stopping clock for room #{state.room_id}")
    
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    {:noreply, %{state | running: false, timer_ref: nil}}
  end

  @impl true
  def handle_info(:beat, state) do
    # ⚠️ CRITICAL: Use Tenants.tenant_topic/3 to construct correct PubSub topic
    # See Roadblock #6 - Channel/PubSub topic matching
    tenant_topic = Tenants.tenant_topic(state.tenant_id, "music_room:#{state.room_id}", true)
    
    Phoenix.PubSub.broadcast(
      Realtime.PubSub,
      tenant_topic,
      {:beat, state.beat}
    )
    
    # ⚠️ See Roadblock #4 - Recalculate schedule to prevent drift
    # Schedule next beat from current time (not from previous schedule)
    timer_ref = schedule_beat(state.bpm)
    
    {:noreply, %{state | beat: state.beat + 1, timer_ref: timer_ref}}
  end

  ## Private Functions
  
  defp schedule_beat(bpm) do
    ms_per_beat = div(60_000, bpm)
    Process.send_after(self(), :beat, ms_per_beat)
  end

  # ⚠️ CRITICAL: Include tenant_id in registry key to prevent collisions
  # See Roadblock #3 - Process Registry Key Collisions
  defp via_tuple(room_id, tenant_id) do
    {:via, Registry, {Realtime.Music.Registry, {:tempo_server, tenant_id, room_id}}}
  end
end
```

#### Critical Logic: Beat Scheduling

**Key Points:**
- `ms_per_beat = 60_000 / bpm` (e.g., 120 BPM = 500ms per beat)
- `Process.send_after/3` schedules the next beat
- Timer reference stored in state for cancellation
- Beat counter increments on each beat

#### Smoke Test
```elixir
# In IEx console
# ⚠️ Note: Now requires tenant_id
tenant_id = "test-tenant"
iex> {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server("room-123", 120, tenant_id)

# ⚠️ Subscribe to correct PubSub topic (use Tenants.tenant_topic/3)
iex> tenant_topic = Realtime.Tenants.tenant_topic(tenant_id, "music_room:room-123", true)
iex> Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)

# Start clock
iex> Realtime.Music.TempoServer.start_clock("room-123", tenant_id)

# Wait for beat (should arrive in ~500ms)
iex> receive do
...>   {:beat, beat_number} -> IO.puts("Beat: #{beat_number}")
...> after
...>   600 -> IO.puts("No beat received")
...> end
# Should print: "Beat: 0"

# Verify tempo
iex> Realtime.Music.TempoServer.get_tempo("room-123", tenant_id)
# Should return: {:ok, 120}
```

### Subphase 2.2: Add Supervisor Integration

#### Tasks
- [ ] Add `start_tempo_server/2` to supervisor
- [ ] Add `stop_tempo_server/1` to supervisor
- [ ] Handle process crashes (supervisor auto-restarts)

#### Files to Modify

**`lib/extensions/music/supervisor.ex`** - Complete implementation:

```elixir
defmodule Realtime.Music.Supervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(
      name: __MODULE__,
      strategy: :one_for_one
    )
  end

  @doc """
  Start a tempo server for a room.
  ⚠️ Requires tenant_id - see Roadblock #1
  """
  def start_tempo_server(room_id, bpm, tenant_id) do
    spec = {Realtime.Music.TempoServer, {room_id, bpm, tenant_id}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop a tempo server for a room.
  ⚠️ Requires tenant_id - see Roadblock #3
  """
  def stop_tempo_server(room_id, tenant_id) do
    case Registry.lookup(Realtime.Music.Registry, {:tempo_server, tenant_id, room_id}) do
      [{pid, _}] -> 
        DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> 
        {:error, :not_found}
    end
  end
end
```

#### Smoke Test
```elixir
# Start tempo server
iex> {:ok, pid} = Realtime.Music.Supervisor.start_tempo_server("room-456", 140)
# Should return: {:ok, #PID<...>}

# Verify it's running
iex> Process.alive?(pid)
# Should return: true

# Stop tempo server
iex> Realtime.Music.Supervisor.stop_tempo_server("room-456")
# Should return: :ok

# Verify it's stopped
iex> Process.alive?(pid)
# Should return: false
```

### Subphase 2.3: Add Tempo Change Handling

#### Tasks
- [ ] Handle tempo changes while clock is running
- [ ] Cancel old timer and schedule new one
- [ ] Update state atomically

#### Files to Modify

**Already implemented in Subphase 2.1** - `handle_cast({:set_tempo, bpm}, state)` handles this.

#### Critical Logic: Tempo Change While Running

**Key Points:**
- Cancel existing timer before scheduling new one
- Only reschedule if clock is running
- Atomic state update prevents race conditions

#### Smoke Test
```elixir
# Start tempo server and clock
iex> {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server("room-789", 60)
iex> Realtime.Music.TempoServer.start_clock("room-789")

# Subscribe to beats
iex> Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:music_room:room-789")

# Wait for first beat (slow tempo)
iex> receive do
...>   {:beat, _} -> :ok
...> after
...>   1200 -> :timeout
...> end

# Change tempo while running
iex> Realtime.Music.TempoServer.set_tempo("room-789", 180)

# Verify new tempo
iex> Realtime.Music.TempoServer.get_tempo("room-789")
# Should return: {:ok, 180}

# Next beat should arrive faster (~333ms instead of ~1000ms)
iex> receive do
...>   {:beat, _} -> IO.puts("Fast beat received")
...> after
...>   500 -> IO.puts("Timeout")
...> end
# Should print: "Fast beat received"
```

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 2**

---

## Phase 3: Music Room Channel (Day 6-8)

### Goal
Create a custom channel for music rooms that integrates with tempo server and handles music-specific events.

### Subphase 3.1: Create Basic Channel Structure

#### Tasks
- [ ] Create `lib/realtime_web/channels/music_room_channel.ex`
- [ ] Implement basic `join/3` function
- [ ] Register channel in `user_socket.ex`

#### Files to Create

**`lib/realtime_web/channels/music_room_channel.ex`** - Basic structure:

```elixir
defmodule RealtimeWeb.MusicRoomChannel do
  @moduledoc """
  Phoenix Channel for collaborative music rooms.
  
  Handles:
  - Student connections
  - Note broadcasting
  - Tempo changes
  - Teacher controls
  """
  use RealtimeWeb, :channel

  alias Realtime.Music.{TempoServer, SessionManager}

  @doc """
  Join a music room.
  
  Channel topic format: "music_room:ROOM_CODE"
  Example: "music_room:MUSIC-2024"
  """
  def join("music_room:" <> room_id, params, socket) do
    # Validate room exists
    case SessionManager.get_room(room_id) do
      {:ok, _room} ->
        # Assign room_id and role to socket
        socket = socket
          |> assign(:room_id, room_id)
          |> assign(:student_id, params["student_id"])
          |> assign(:role, params["role"] || "student")
        
        {:ok, %{room_id: room_id}, socket}
      
      {:error, :not_found} ->
        {:error, %{reason: "Room not found"}}
    end
  end

  # Placeholder handlers (to be implemented in Subphase 3.2)
  def handle_in("play_note", _payload, socket) do
    {:noreply, socket}
  end
end
```

#### Files to Modify

**`lib/realtime_web/channels/user_socket.ex`** - Add channel route:

```elixir
defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket
  
  ## Channels
  channel "realtime:*", RealtimeChannel
  # Add this:
  channel "music_room:*", RealtimeWeb.MusicRoomChannel
```

#### Smoke Test
```javascript
// Using Supabase JS client
import { createClient } from '@supabase/supabase-js'

const supabase = createClient('http://localhost:4000', 'your-jwt-token')

// Try to join room (will fail until SessionManager is implemented)
const channel = supabase.channel('music_room:test-room')
channel.subscribe((status) => {
  console.log('Status:', status)
  // Will show error until Phase 4 (SessionManager)
})
```

### Subphase 3.2: Implement Note Broadcasting

#### Tasks
- [ ] Implement `handle_in("play_note", payload, socket)`
- [ ] Broadcast note to all students in room
- [ ] Include student_id and timestamp

#### Files to Modify

**`lib/realtime_web/channels/music_room_channel.ex`** - Add note handler:

```elixir
@doc """
Handle incoming "play_note" event from student.
Broadcast to all students in room.
"""
def handle_in("play_note", %{"midi" => midi}, socket) do
  # Broadcast to all students in room
  broadcast!(socket, "student_note", %{
    midi: midi,
    student_id: socket.assigns.student_id,
    timestamp: System.system_time(:millisecond)
  })
  
  {:noreply, socket}
end

def handle_in("play_note", _payload, socket) do
  # Invalid payload (missing midi)
  {:reply, {:error, %{reason: "midi required"}}, socket}
end
```

#### Critical Logic: Broadcast

**Key Points:**
- `broadcast!/3` sends to all clients in the channel (except sender if `self: false`)
- Payload includes student_id for identification
- Timestamp for latency measurement

#### Smoke Test
```elixir
# In IEx, create a test room first (Phase 4)
# For now, manually create room state
iex> # This will work after Phase 4

# Or test with WebSocket client
# 1. Join channel
# 2. Send play_note event
# 3. Verify broadcast received
```

### Subphase 3.3: Integrate Tempo Server

#### Tasks
- [ ] Start tempo server when room is joined
- [ ] Subscribe to beat events from tempo server
- [ ] Broadcast beats to channel clients

#### Files to Modify

**`lib/realtime_web/channels/music_room_channel.ex`** - Update join and add beat handler:

```elixir
def join("music_room:" <> room_id, params, socket) do
  case SessionManager.get_room(room_id) do
    {:ok, room} ->
      socket = socket
        |> assign(:room_id, room_id)
        |> assign(:student_id, params["student_id"])
        |> assign(:role, params["role"] || "student")
      
      # Start tempo server if not already running
      case Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id}) do
        [] ->
          # Start tempo server with room's BPM
          Realtime.Music.Supervisor.start_tempo_server(room_id, room.bpm)
        _ ->
          :ok  # Already running
      end
      
      # Subscribe to beat events from tempo server
      tenant_topic = "realtime:music_room:#{room_id}"
      Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)
      
      # Start tempo clock
      TempoServer.start_clock(room_id)
      
      {:ok, %{room_id: room_id, bpm: room.bpm}, socket}
    
    {:error, :not_found} ->
      {:error, %{reason: "Room not found"}}
  end
end

@doc """
Handle beat events from tempo server.
"""
def handle_info({:beat, beat_number}, socket) do
  # Broadcast beat to all clients in channel
  push(socket, "beat", %{beat: beat_number})
  {:noreply, socket}
end
```

#### Critical Logic: PubSub Subscription

**Key Points:**
- Tempo server broadcasts to PubSub topic
- Channel subscribes to same topic
- `handle_info/2` receives beat events
- `push/2` sends to WebSocket client

#### Smoke Test
```elixir
# After Phase 4 (SessionManager), test full flow:
# 1. Create room
# 2. Join channel
# 3. Verify beats are received
```

### Subphase 3.4: Implement Teacher Controls

#### Tasks
- [ ] Implement `handle_in("set_tempo", payload, socket)` (teacher only)
- [ ] Implement `handle_in("mute_student", payload, socket)` (teacher only)
- [ ] Implement `handle_in("assign_beat", payload, socket)` (teacher only)
- [ ] Add authorization checks

#### Files to Modify

**`lib/realtime_web/channels/music_room_channel.ex`** - Add teacher handlers:

```elixir
@doc """
Handle tempo change (teacher only).
"""
def handle_in("set_tempo", %{"bpm" => bpm}, socket) when is_integer(bpm) do
  if socket.assigns.role == "teacher" do
    room_id = socket.assigns.room_id
    
    # Update tempo server
    :ok = TempoServer.set_tempo(room_id, bpm)
    
    # Broadcast to all students
    broadcast!(socket, "tempo_changed", %{bpm: bpm})
    
    {:reply, :ok, socket}
  else
    {:reply, {:error, %{reason: "unauthorized"}}, socket}
  end
end

@doc """
Handle mute student (teacher only).
"""
def handle_in("mute_student", %{"student_id" => student_id}, socket) do
  if socket.assigns.role == "teacher" do
    broadcast!(socket, "student_muted", %{student_id: student_id})
    {:reply, :ok, socket}
  else
    {:reply, {:error, %{reason: "unauthorized"}}, socket}
  end
end

@doc """
Handle assign beat (teacher only).
"""
def handle_in("assign_beat", %{"student_id" => student_id, "beat" => beat}, socket) do
  if socket.assigns.role == "teacher" do
    broadcast!(socket, "beat_assigned", %{
      student_id: student_id,
      beat: beat
    })
    {:reply, :ok, socket}
  else
    {:reply, {:error, %{reason: "unauthorized"}}, socket}
  end
end
```

#### Critical Logic: Authorization

**Key Points:**
- Check `socket.assigns.role` before allowing action
- Return `{:error, %{reason: "unauthorized"}}` for non-teachers
- All teacher actions broadcast to channel

#### Smoke Test
```elixir
# Test teacher can set tempo
# Test student cannot set tempo
# Verify broadcasts work correctly
```

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 3**

---

## Phase 4: Session Management (Day 9-10)

### Goal
Implement room creation, join codes, and session state management.

### Subphase 4.1: Implement Room Creation

#### Tasks
- [ ] Implement `create_room/2` in SessionManager
- [ ] Generate unique join codes
- [ ] Store room state
- [ ] Start tempo server for new room

#### Files to Modify

**`lib/extensions/music/session_manager.ex`** - Implement room creation:

```elixir
defmodule Realtime.Music.SessionManager do
  use GenServer
  alias Realtime.Music.TempoSupervisor

  ## Client API
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Create a new music room.
  
  ⚠️ CRITICAL: Requires tenant_id - see Roadblock #2
  
  Returns: {:ok, room_id} where room_id is a unique join code
  """
  def create_room(teacher_id, tenant_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create_room, teacher_id, tenant_id, opts})
  end

  @doc """
  Get room information.
  """
  def get_room(room_id) do
    GenServer.call(__MODULE__, {:get_room, room_id})
  end

  @doc """
  Close a room.
  """
  def close_room(room_id) do
    GenServer.call(__MODULE__, {:close_room, room_id})
  end

  ## Server Callbacks
  
  @impl true
  def init(_) do
    # State: %{room_id => %{teacher_id, bpm, created_at, students}}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_room, teacher_id, tenant_id, opts}, _from, state) do
    room_id = generate_join_code(state)  # ⚠️ Pass state to check duplicates (Roadblock #11)
    bpm = Keyword.get(opts, :bpm, 120)
    
    # ⚠️ Start tempo server with tenant_id (Roadblock #1)
    case Realtime.Music.Supervisor.start_tempo_server(room_id, bpm, tenant_id) do
      {:ok, _pid} ->
        room = %{
          room_id: room_id,
          tenant_id: tenant_id,  # ⚠️ Store tenant_id (Roadblock #2)
          teacher_id: teacher_id,
          bpm: bpm,
          created_at: System.system_time(:second),
          students: []
        }
        
        {:reply, {:ok, room_id}, Map.put(state, room_id, room)}
      
      error ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:get_room, room_id}, _from, state) do
    case Map.get(state, room_id) do
      nil -> 
        {:reply, {:error, :not_found}, state}
      room -> 
        {:reply, {:ok, room}, state}
    end
  end

  @impl true
  def handle_call({:close_room, room_id}, _from, state) do
    # Get tenant_id from room state
    case Map.get(state, room_id) do
      %{tenant_id: tenant_id} ->
        # Stop tempo server with tenant_id
        Realtime.Music.Supervisor.stop_tempo_server(room_id, tenant_id)
        {:reply, :ok, Map.delete(state, room_id)}
      
      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Private Functions
  
  # ⚠️ Check for duplicates to prevent collisions (Roadblock #11)
  defp generate_join_code(state) do
    code = "MUSIC-#{:rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")}"
    
    if Map.has_key?(state, code) do
      generate_join_code(state)  # Retry if collision
    else
      code
    end
  end
end
```

#### Critical Logic: Join Code Generation

**Key Points:**
- Format: `"MUSIC-####"` where #### is 4-digit number
- Use `:rand.uniform/1` for randomness
- Pad with zeros for consistent format
- Consider checking for duplicates (optional)

#### Smoke Test
```elixir
# In IEx console
# ⚠️ Note: Now requires tenant_id
tenant_id = "test-tenant"
iex> {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", tenant_id, bpm: 120)
# Should return: {:ok, "MUSIC-1234"} (or similar)

iex> String.starts_with?(room_id, "MUSIC-")
# Should return: true

iex> {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
# Should return room struct

iex> room.teacher_id
# Should return: "teacher-1"

iex> room.tenant_id
# Should return: "test-tenant"

iex> room.bpm
# Should return: 120
```

### Subphase 4.2: Implement Room Joining

#### Tasks
- [ ] Implement `join_room/2` in SessionManager
- [ ] Track which students are in room
- [ ] Update room state atomically

#### Files to Modify

**`lib/extensions/music/session_manager.ex`** - Add join functionality:

```elixir
@doc """
Join a room.
"""
def join_room(room_id, student_id) do
  GenServer.call(__MODULE__, {:join_room, room_id, student_id})
end

@impl true
def handle_call({:join_room, room_id, student_id}, _from, state) do
  case Map.get(state, room_id) do
    nil ->
      {:reply, {:error, :not_found}, state}
    
    room ->
      # Add student to room if not already present
      students = if student_id in room.students do
        room.students
      else
        [student_id | room.students]
      end
      
      updated_room = %{room | students: students}
      {:reply, :ok, Map.put(state, room_id, updated_room)}
  end
end
```

#### Smoke Test
```elixir
# Create room
iex> {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")

# Join room
iex> :ok = Realtime.Music.SessionManager.join_room(room_id, "student-1")

# Verify student is in room
iex> {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
iex> "student-1" in room.students
# Should return: true
```

### Subphase 4.3: Integrate with Channel

#### Tasks
- [ ] Update MusicRoomChannel to use SessionManager
- [ ] Call `join_room/2` when student joins channel
- [ ] Handle room cleanup on disconnect

#### Files to Modify

**`lib/realtime_web/channels/music_room_channel.ex`** - Update join:

```elixir
def join("music_room:" <> room_id, params, socket) do
  # ⚠️ CRITICAL: Get tenant_id from socket (Roadblock #1, #2)
  tenant_id = socket.assigns.tenant
  
  case SessionManager.get_room(room_id) do
    {:ok, room} ->
      student_id = params["student_id"]
      
      # Join room (track student)
      :ok = SessionManager.join_room(room_id, student_id)
      
      socket = socket
        |> assign(:room_id, room_id)
        |> assign(:tenant_id, tenant_id)  # Store tenant_id in socket
        |> assign(:student_id, student_id)
        |> assign(:role, params["role"] || "student")
      
      # ⚠️ Start tempo server with tenant_id (Roadblock #1, #3)
      case Registry.lookup(Realtime.Music.Registry, {:tempo_server, tenant_id, room_id}) do
        [] ->
          Realtime.Music.Supervisor.start_tempo_server(room_id, room.bpm, tenant_id)
        _ ->
          :ok
      end
      
      # ⚠️ CRITICAL: Use Tenants.tenant_topic/3 for correct PubSub topic (Roadblock #6)
      tenant_topic = Tenants.tenant_topic(tenant_id, "music_room:#{room_id}", true)
      Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)
      
      # Start tempo clock with tenant_id
      TempoServer.start_clock(room_id, tenant_id)
      
      {:ok, %{room_id: room_id, bpm: room.bpm}, socket}
    
    {:error, :not_found} ->
      {:error, %{reason: "Room not found"}}
  end
end

@impl true
def terminate(_reason, socket) do
  # Optional: Remove student from room on disconnect
  # Could be handled by presence system instead
  :ok
end
```

#### Smoke Test
```javascript
// Full end-to-end test
// 1. Teacher creates room (via API or IEx)
// 2. Student joins channel with room_id
// 3. Verify student can play notes
// 4. Verify beats are received
```

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 4**

---

## Phase 5: Integration & Polish (Day 11-12)

### Goal
Integrate all components, add error handling, and polish the implementation.

### Subphase 5.1: Error Handling

#### Tasks
- [ ] Handle room not found errors
- [ ] Handle tempo server crashes
- [ ] Handle invalid BPM values
- [ ] Handle duplicate room joins

#### Files to Modify

**`lib/extensions/music/tempo_server.ex`** - Add validation:

```elixir
def set_tempo(room_id, bpm) when is_integer(bpm) and bpm > 0 and bpm < 300 do
  GenServer.cast(via_tuple(room_id), {:set_tempo, bpm})
end

def set_tempo(_room_id, bpm) do
  {:error, :invalid_bpm}
end
```

**`lib/realtime_web/channels/music_room_channel.ex`** - Add error handling:

```elixir
def handle_in("set_tempo", %{"bpm" => bpm}, socket) when is_integer(bpm) do
  # ⚠️ Get tenant_id from socket assigns
  tenant_id = socket.assigns.tenant_id
  room_id = socket.assigns.room_id
  
  case TempoServer.set_tempo(room_id, tenant_id, bpm) do
    :ok ->
      broadcast!(socket, "tempo_changed", %{bpm: bpm})
      {:reply, :ok, socket}
    
    {:error, :invalid_bpm} ->
      {:reply, {:error, %{reason: "BPM must be between 1 and 299"}}, socket}
  end
end
```

### Subphase 5.2: Documentation

#### Tasks
- [ ] Add module docs to all music modules
- [ ] Add function docs with examples
- [ ] Update README with music extension usage

### Subphase 5.3: Performance & Optimization

#### Tasks
- [ ] Verify tempo server accuracy (timing)
- [ ] Check memory usage (process heap)
- [ ] Verify PubSub topic efficiency

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 5**

---

## Phase 6: SEL Data Integration (Optional, Day 13-14)

### Goal
Add SEL data collection hooks (participation tracking, reflections).

### Subphase 6.1: Create SEL Tracker Module

#### Tasks
- [ ] Create `lib/extensions/music/sel_tracker.ex`
- [ ] Implement `log_participation/3`
- [ ] Implement `log_reflection/3`
- [ ] Store in database (create migrations)

### Subphase 6.2: Integration Points

#### Tasks
- [ ] Log note plays as participation events
- [ ] Log tempo changes as teacher actions
- [ ] Add reflection endpoint (HTTP API)

### Subphase 6.3: Database Schema

#### Tasks
- [ ] Create `participation_events` table
- [ ] Create `student_reflections` table
- [ ] Add indexes for queries

#### High-Value Tests
See `docs/IMPLEMENTATION_TESTS.md` → **Phase 6**

---

## Success Criteria

### Must Have (MVP)
- ✅ Music room channel working
- ✅ Tempo clock broadcasting beats
- ✅ Teacher can set tempo
- ✅ Students can play notes (broadcast)
- ✅ Session management (create/join rooms)
- ✅ All tests passing

### Nice to Have
- ✅ SEL data collection
- ✅ Comprehensive error handling
- ✅ Documentation
- ✅ Performance optimization

---

## Estimated Timeline

- **Phase 0**: 1 day (setup)
- **Phase 1**: 2 days (extension foundation)
- **Phase 2**: 2 days (tempo server)
- **Phase 3**: 3 days (music room channel)
- **Phase 4**: 2 days (session management)
- **Phase 5**: 2 days (integration & polish)
- **Phase 6**: 2 days (SEL, optional)

**Total: 12-14 days** (with SEL) or **10-12 days** (without SEL)

---

## Next Steps After Implementation

1. **Deployment**: Deploy to Fly.io or similar
2. **Frontend Integration**: Connect React/Tone.js frontend
3. **Performance Testing**: Load test with 20+ concurrent students
4. **Documentation**: API docs, usage examples
5. **Community**: Consider contributing back to Supabase Realtime

---

**Remember:** Reference `docs/IMPLEMENTATION_TESTS.md` for detailed test examples for each phase/subphase.
