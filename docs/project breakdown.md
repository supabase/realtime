# Developer #1: Supabase Realtime Music Extensions

## Project 1: Fork Supabase Realtime and Build Music Education Infrastructure

**Timeline**: 10-12 days  
**Language**: Elixir  
**Repository**: https://github.com/supabase/realtime (7,400+ stars)

---

## What Developer #1 Will Build

### High-Level Summary

Fork Supabase Realtime and add **music education extensions** that enable real-time collaborative music games for classrooms.

**Core deliverables**:
1. Music room channels (classroom sessions)
2. Tempo clock server (synchronized metronome)
3. Teacher controls (tempo, muting, role assignment)
4. Session management (join codes, room creation)
5. SEL data integration (reflections, analytics)

---

## Detailed Breakdown

### Day 1-2: Setup and Learning

#### Goals
- Fork repository
- Get local development environment running
- Understand codebase structure
- Read Elixir/Phoenix basics

#### Tasks

**1. Fork and clone**:
```bash
# Fork on GitHub
# Clone locally
git clone https://github.com/YOUR_USERNAME/realtime.git
cd realtime
```

**2. Install dependencies**:
```bash
# Install Elixir (via asdf or homebrew)
brew install elixir

# Install Postgres (for local development)
brew install postgresql

# Install dependencies
mix deps.get
```

**3. Run locally**:
```bash
# Start Postgres
brew services start postgresql

# Create database
mix ecto.create

# Run migrations
mix ecto.migrate

# Start server
mix phx.server
```

**4. Explore codebase**:
- Read `lib/realtime_web/channels/` (existing channels)
- Read `lib/realtime/` (core logic)
- Run existing tests: `mix test`
- Try connecting a client (use Supabase JS library)

**5. Learn Elixir basics**:
- Pattern matching
- Processes and message passing
- GenServer (generic server behavior)
- Phoenix Channels

**Resources**:
- Elixir Getting Started: https://elixir-lang.org/getting-started/introduction.html
- Phoenix Channels Guide: https://hexdocs.pm/phoenix/channels.html

---

### Day 3-4: Music Room Channel

#### Goal
Create a custom Phoenix Channel for music rooms with basic functionality.

#### What to Build

**File**: `lib/realtime_web/channels/music_room_channel.ex`

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
  use Phoenix.Channel
  alias Realtime.Music.{TempoServer, SessionManager}

  @doc """
  Join a music room.
  
  Channel topic format: "music_room:ROOM_CODE"
  Example: "music_room:MUSIC-2024"
  
  Params:
  - student_id: Unique student identifier
  - name: Student name
  - role: "student" or "teacher"
  """
  def join("music_room:" <> room_id, params, socket) do
    # Validate room exists
    case SessionManager.get_room(room_id) do
      {:ok, room} ->
        # Assign room_id and role to socket
        socket = socket
          |> assign(:room_id, room_id)
          |> assign(:student_id, params["student_id"])
          |> assign(:role, params["role"] || "student")
        
        # Send current room state to joining client
        send(self(), :after_join)
        
        {:ok, %{room: room}, socket}
      
      {:error, :not_found} ->
        {:error, %{reason: "Room not found"}}
    end
  end

  @doc """
  After join, send current room state and track presence.
  """
  def handle_info(:after_join, socket) do
    # Get current tempo
    {:ok, tempo} = TempoServer.get_tempo(socket.assigns.room_id)
    
    # Send to client
    push(socket, "room_state", %{
      tempo: tempo,
      room_id: socket.assigns.room_id
    })
    
    # Track presence
    {:ok, _} = Presence.track(socket, socket.assigns.student_id, %{
      student_id: socket.assigns.student_id,
      name: socket.assigns.name,
      role: socket.assigns.role,
      online_at: System.system_time(:second)
    })
    
    {:noreply, socket}
  end

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

  @doc """
  Handle tempo change (teacher only).
  """
  def handle_in("set_tempo", %{"bpm" => bpm}, socket) do
    if socket.assigns.role == "teacher" do
      # Update tempo server
      :ok = TempoServer.set_tempo(socket.assigns.room_id, bpm)
      
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
end
```

#### Testing

**File**: `test/realtime_web/channels/music_room_channel_test.exs`

```elixir
defmodule RealtimeWeb.MusicRoomChannelTest do
  use RealtimeWeb.ChannelCase
  alias RealtimeWeb.MusicRoomChannel

  setup do
    # Create test room
    {:ok, room_id} = SessionManager.create_room("teacher-1")
    
    # Connect student socket
    {:ok, _, socket} = socket("student:1", %{})
      |> subscribe_and_join(MusicRoomChannel, "music_room:#{room_id}", %{
        "student_id" => "student-1",
        "name" => "Alice",
        "role" => "student"
      })
    
    {:ok, socket: socket, room_id: room_id}
  end

  test "student can play note", %{socket: socket} do
    ref = push(socket, "play_note", %{"midi" => 60})
    assert_reply ref, :ok
    assert_broadcast "student_note", %{midi: 60, student_id: "student-1"}
  end

  test "teacher can set tempo", %{room_id: room_id} do
    # Connect teacher socket
    {:ok, _, teacher_socket} = socket("teacher:1", %{})
      |> subscribe_and_join(MusicRoomChannel, "music_room:#{room_id}", %{
        "student_id" => "teacher-1",
        "role" => "teacher"
      })
    
    ref = push(teacher_socket, "set_tempo", %{"bpm" => 140})
    assert_reply ref, :ok
    assert_broadcast "tempo_changed", %{bpm: 140}
  end

  test "student cannot set tempo", %{socket: socket} do
    ref = push(socket, "set_tempo", %{"bpm" => 140})
    assert_reply ref, :error, %{reason: "unauthorized"}
  end
end
```

---

### Day 5-6: Tempo Clock Server

#### Goal
Create a GenServer that broadcasts beat events at a given BPM.

#### What to Build

**File**: `lib/realtime/music/tempo_server.ex`

```elixir
defmodule Realtime.Music.TempoServer do
  @moduledoc """
  GenServer that maintains a tempo clock and broadcasts beat events.
  
  Each music room has its own TempoServer process.
  The server sends beat events at the specified BPM to all clients in the room.
  """
  use GenServer
  require Logger

  @doc """
  Start a tempo server for a room.
  
  Args:
  - room_id: Unique room identifier
  - bpm: Beats per minute (default: 120)
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

  @doc """
  Set tempo for a room.
  """
  def set_tempo(room_id, bpm) when bpm > 0 and bpm < 300 do
    GenServer.cast(via_tuple(room_id), {:set_tempo, bpm})
  end

  @doc """
  Start the tempo clock.
  """
  def start_clock(room_id) do
    GenServer.cast(via_tuple(room_id), :start_clock)
  end

  @doc """
  Stop the tempo clock.
  """
  def stop_clock(room_id) do
    GenServer.cast(via_tuple(room_id), :stop_clock)
  end

  ## Server Callbacks

  @impl true
  def init({room_id, bpm}) do
    Logger.info("Starting tempo server for room #{room_id} at #{bpm} BPM")
    
    state = %{
      room_id: room_id,
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
    
    # Schedule next beat with new tempo
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
    # Broadcast beat to all clients in room
    Phoenix.PubSub.broadcast(
      Realtime.PubSub,
      "music_room:#{state.room_id}",
      {:beat, state.beat}
    )
    
    # Schedule next beat
    timer_ref = schedule_beat(state.bpm)
    
    {:noreply, %{state | beat: state.beat + 1, timer_ref: timer_ref}}
  end

  ## Private Functions

  defp schedule_beat(bpm) do
    ms_per_beat = div(60_000, bpm)
    Process.send_after(self(), :beat, ms_per_beat)
  end

  defp via_tuple(room_id) do
    {:via, Registry, {Realtime.Music.Registry, {:tempo_server, room_id}}}
  end
end
```

**File**: `lib/realtime/music/tempo_supervisor.ex`

```elixir
defmodule Realtime.Music.TempoSupervisor do
  @moduledoc """
  DynamicSupervisor for tempo servers.
  Starts and supervises tempo servers for each music room.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a tempo server for a room.
  """
  def start_tempo_server(room_id, bpm \\ 120) do
    spec = {Realtime.Music.TempoServer, {room_id, bpm}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop a tempo server for a room.
  """
  def stop_tempo_server(room_id) do
    case Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
```

---

### Day 7-8: Session Management

#### Goal
Create session management for creating rooms, generating join codes, and tracking room state.

#### What to Build

**File**: `lib/realtime/music/session_manager.ex`

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
  alias Realtime.Music.TempoSupervisor

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Create a new music room.
  
  Returns: {:ok, room_id} where room_id is a unique join code
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
  def handle_call({:create_room, teacher_id, opts}, _from, state) do
    room_id = generate_join_code()
    bpm = Keyword.get(opts, :bpm, 120)
    
    # Start tempo server for this room
    {:ok, _pid} = TempoSupervisor.start_tempo_server(room_id, bpm)
    
    room = %{
      room_id: room_id,
      teacher_id: teacher_id,
      bpm: bpm,
      created_at: System.system_time(:second),
      students: []
    }
    
    {:reply, {:ok, room_id}, Map.put(state, room_id, room)}
  end

  @impl true
  def handle_call({:get_room, room_id}, _from, state) do
    case Map.get(state, room_id) do
      nil -> {:reply, {:error, :not_found}, state}
      room -> {:reply, {:ok, room}, state}
    end
  end

  @impl true
  def handle_call({:close_room, room_id}, _from, state) do
    # Stop tempo server
    TempoSupervisor.stop_tempo_server(room_id)
    
    # Remove from state
    {:reply, :ok, Map.delete(state, room_id)}
  end

  ## Private Functions

  defp generate_join_code do
    # Generate code like "MUSIC-2024"
    number = :rand.uniform(9999)
    "MUSIC-#{String.pad_leading(Integer.to_string(number), 4, "0")}"
  end
end
```

---

### Day 9-10: SEL Data Integration

#### Goal
Add support for collecting and broadcasting SEL (social-emotional learning) data.

#### What to Build

**File**: `lib/realtime/music/sel_tracker.ex`

```elixir
defmodule Realtime.Music.SELTracker do
  @moduledoc """
  Tracks social-emotional learning data from music games.
  
  Handles:
  - Student reflections
  - Participation metrics
  - Collaboration scores
  - Emotional check-ins
  """

  @doc """
  Log a student reflection.
  """
  def log_reflection(room_id, student_id, reflection) do
    # Insert into database
    %{
      room_id: room_id,
      student_id: student_id,
      reflection: reflection,
      timestamp: System.system_time(:second)
    }
    |> insert_reflection()
    
    # Broadcast to teacher dashboard (via Postgres Changes)
    :ok
  end

  @doc """
  Log participation event.
  """
  def log_participation(room_id, student_id, event_type) do
    # Track: note_played, turn_taken, helped_peer, etc.
    %{
      room_id: room_id,
      student_id: student_id,
      event_type: event_type,
      timestamp: System.system_time(:millisecond)
    }
    |> insert_participation()
  end

  @doc """
  Get SEL summary for a student.
  """
  def get_student_summary(student_id) do
    # Aggregate data: participation count, reflections, collaboration score
    %{
      total_notes_played: count_notes(student_id),
      total_sessions: count_sessions(student_id),
      reflections: get_reflections(student_id),
      collaboration_score: calculate_collaboration_score(student_id)
    }
  end

  # Private functions for database operations
  defp insert_reflection(data), do: # ...
  defp insert_participation(data), do: # ...
  defp count_notes(student_id), do: # ...
  defp count_sessions(student_id), do: # ...
  defp get_reflections(student_id), do: # ...
  defp calculate_collaboration_score(student_id), do: # ...
end
```

---

### Day 11-12: Testing, Documentation, Deployment

#### Goals
- Write comprehensive tests
- Document API and usage
- Deploy to Fly.io
- Create example client

#### Tasks

**1. Testing**:
```bash
# Run all tests
mix test

# Run with coverage
mix test --cover
```

**2. Documentation**:
```elixir
# Generate docs
mix docs

# View docs
open doc/index.html
```

**3. Deployment to Fly.io**:
```bash
# Install flyctl
brew install flyctl

# Login
fly auth login

# Launch app
fly launch

# Deploy
fly deploy

# Check status
fly status
```

**4. Example client** (JavaScript):
```javascript
// example_client.js
import { createClient } from '@supabase/supabase-js'

const client = createClient('https://your-realtime-server.fly.dev', 'anon-key')

// Create room (teacher)
async function createRoom() {
  const response = await fetch('https://your-realtime-server.fly.dev/api/rooms', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ teacher_id: 'teacher-1', bpm: 120 })
  })
  const { room_id } = await response.json()
  return room_id
}

// Join room (student)
async function joinRoom(roomId, studentId, name) {
  const channel = client.channel(`music_room:${roomId}`)
  
  await channel.subscribe((status) => {
    if (status === 'SUBSCRIBED') {
      console.log('Joined room!')
      
      // Track presence
      channel.track({
        student_id: studentId,
        name: name,
        role: 'student'
      })
    }
  })
  
  // Listen to beats
  channel.on('broadcast', { event: 'beat' }, ({ payload }) => {
    console.log('Beat:', payload.beat)
  })
  
  // Listen to notes
  channel.on('broadcast', { event: 'student_note' }, ({ payload }) => {
    console.log('Note played:', payload.midi)
  })
  
  return channel
}

// Play note
function playNote(channel, midi) {
  channel.send({
    type: 'broadcast',
    event: 'play_note',
    payload: { midi }
  })
}
```

---

## Deliverables

### Code
1. ✅ Music room channel (`music_room_channel.ex`)
2. ✅ Tempo server (`tempo_server.ex`)
3. ✅ Session manager (`session_manager.ex`)
4. ✅ SEL tracker (`sel_tracker.ex`)
5. ✅ Tests (>80% coverage)

### Documentation
1. ✅ API documentation (ExDoc)
2. ✅ Usage guide (README)
3. ✅ Example client code

### Deployment
1. ✅ Deployed to Fly.io
2. ✅ Public URL for testing
3. ✅ Environment configuration

---

## How This Enables Project 2

### What Project 2 Gets

**From Developer #1's work**:
- ✅ Real-time multiplayer server (Supabase Realtime + music extensions)
- ✅ Tempo synchronization (all students hear beats at same time)
- ✅ Note broadcasting (low-latency note events)
- ✅ Teacher controls (tempo, muting, role assignment)
- ✅ Session management (join codes, room creation)
- ✅ SEL data collection (reflections, participation tracking)

**What Project 2 builds**:
- Frontend UI (React + Tone.js)
- Game mechanics (Rhythm Circle, Melody Builder, etc.)
- Audio synthesis (Tone.js)
- Visual feedback (animations, score display)
- Teacher dashboard (analytics, controls)

**The split**: 70% infrastructure (Project 1) + 30% game design (Project 2) = Complete product

---

## Risk Mitigation

### Potential Issues

**1. Elixir learning curve**
- **Mitigation**: Start with tutorials, read existing Supabase Realtime code, ask community for help

**2. Tempo clock precision**
- **Mitigation**: Use Erlang's timer module (accurate to ~1ms), test with multiple clients

**3. Deployment complexity**
- **Mitigation**: Use Fly.io (Elixir-native), follow official guides, start with simple config

**4. Scope creep**
- **Mitigation**: Stick to MVP (4 core features), defer nice-to-haves to Project 2

---

## Success Criteria

### Must Have (MVP)
- ✅ Music room channel working
- ✅ Tempo clock broadcasting beats
- ✅ Teacher can set tempo
- ✅ Students can play notes (broadcast)
- ✅ Deployed to Fly.io

### Nice to Have
- ✅ SEL data collection
- ✅ Comprehensive tests
- ✅ Example client
- ✅ Documentation

### Stretch Goals
- ⭐ Contribute back to Supabase Realtime
- ⭐ Multi-room support (multiple classrooms)
- ⭐ Recording/playback

---

## The Bottom Line

**Developer #1 builds the multiplayer infrastructure** that enables real-time collaborative music games.

**Timeline**: 10-12 days (learning + building)

**Outcome**: Production-ready Elixir/Phoenix server with music education extensions, deployed to Fly.io, ready for Project 2 frontend integration.

**Next**: Developer #2 builds frontend (Tone.js + React) that connects to this backend!
