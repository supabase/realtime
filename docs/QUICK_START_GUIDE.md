# Quick Start Guide: Understanding This Repo

## What Is This?

This is **Supabase Realtime** - a production-grade Elixir/Phoenix server for real-time WebSocket communication. You're extending it to support **collaborative music education games** for K-5 classrooms.

---

## The Big Picture

### What You're Building

A real-time multiplayer backend for music games where:
- **20+ students** can play music together synchronously
- **Teachers** can control tempo, mute students, assign roles
- **Low latency** (< 100ms) for rhythm synchronization
- **SEL data collection** (participation, reflections, collaboration metrics)

### How It Works

```
Students/Teachers (WebSocket)
         ↓
    Realtime Server (Elixir/Phoenix)
         ↓
    ┌────┴────┐
    ↓         ↓
Channels   Tempo Servers
(Broadcast) (Beat Events)
```

**Key Components:**
1. **Channels** - Real-time communication rooms (like chat rooms)
2. **Broadcast** - Send messages to all clients in a channel
3. **Presence** - Track who's online and what they're doing
4. **Tempo Servers** - GenServer processes that broadcast beat events

---

## Core Concepts (5-Minute Overview)

### 1. Tenants = Projects

Each **tenant** is a separate project/database:
- Example: `"music-classroom-1"` is a tenant
- Each tenant has its own configuration, rate limits, extensions
- Stored in `_realtime.tenants` table

**Why it matters:** You can have multiple classrooms (tenants) running on the same server.

### 2. Channels = Rooms

A **channel** is a topic clients subscribe to:
- Format: `"realtime:music_room:ABC123"`
- All clients in the same channel receive each other's messages
- One Elixir process per channel connection

**Why it matters:** Each music room is a channel. Students join the channel to play together.

### 3. Broadcast = Messages

**Broadcast** sends ephemeral messages to all clients in a channel:
- Student plays note → Broadcasts to all students
- Teacher changes tempo → Broadcasts to all students
- No persistence (unless private channel)

**Why it matters:** This is how students hear each other's notes in real-time.

### 4. Presence = Shared State

**Presence** tracks shared state across clients:
- Who's online (student list)
- What they're doing (assigned beat, muted status)
- Automatically synced to all clients

**Why it matters:** Teachers can see who's in the room, students can see their peers.

### 5. GenServer = Stateful Processes

**GenServer** is Elixir's way to create stateful processes:
- Tempo server = GenServer that maintains BPM and beat counter
- Each music room can have its own tempo server
- Processes run concurrently (20 students = 20 processes)

**Why it matters:** Tempo servers maintain the metronome clock independently for each room.

---

## How Messages Flow

### Student Plays Note

```
1. Student A presses key
   ↓
2. Frontend: channel.send({ type: "broadcast", event: "play_note", payload: {...} })
   ↓
3. WebSocket → RealtimeChannel.handle_in("broadcast", ...)
   ↓
4. Server validates, checks rate limits
   ↓
5. Publishes to PubSub: "realtime:tenant:music_room:ABC123"
   ↓
6. All subscribed channel processes receive message
   ↓
7. Each process pushes to client: push(socket, "broadcast", {...})
   ↓
8. Students B, C, D... receive and play note
```

### Tempo Clock Beat

```
1. TempoServer: Process.send_after(self(), :beat, 500ms)
   ↓
2. TempoServer.handle_info(:beat, state)
   ↓
3. Broadcasts to PubSub: "realtime:tenant:music_room:ABC123"
   ↓
4. All channel processes receive beat event
   ↓
5. Push to clients: push(socket, "broadcast", {:beat, beat_number})
   ↓
6. All students receive beat and update metronome
```

---

## File Structure Overview

```
lib/
├── realtime/                    # Core Realtime logic
│   ├── application.ex          # App startup, supervisors
│   ├── tenants/                 # Tenant management
│   │   ├── cache.ex             # Tenant lookup/cache
│   │   ├── connect.ex           # Database connection per tenant
│   │   └── ...
│   └── ...
│
├── realtime_web/                # Web/HTTP layer
│   ├── channels/
│   │   ├── user_socket.ex       # WebSocket connection handler
│   │   ├── realtime_channel.ex  # Channel logic (join, broadcast, presence)
│   │   └── ...
│   └── ...
│
└── extensions/                  # Pluggable extensions
    ├── extensions.ex            # Extension registry
    ├── postgres_cdc_rls/        # Postgres Changes extension
    └── music/                   # YOUR MUSIC EXTENSION (to be created)
        ├── supervisor.ex        # Manages music processes
        ├── tempo_server.ex      # Tempo clock GenServer
        └── session_manager.ex   # Room/session management
```

---

## How to Add Music Features

### Step 1: Create Extension Structure

```bash
mkdir -p lib/extensions/music
```

### Step 2: Create Tempo Server

**File: `lib/extensions/music/tempo_server.ex`**
```elixir
defmodule Realtime.Music.TempoServer do
  use GenServer

  def start_link({room_id, bpm}) do
    GenServer.start_link(__MODULE__, {room_id, bpm}, name: via_tuple(room_id))
  end

  def init({room_id, bpm}) do
    schedule_beat(bpm)
    {:ok, %{room_id: room_id, bpm: bpm, beat: 0}}
  end

  def handle_info(:beat, state) do
    # Broadcast beat to channel
    Phoenix.PubSub.broadcast(
      Realtime.PubSub,
      "realtime:tenant_id:music_room:#{state.room_id}",
      {:beat, state.beat}
    )
    
    schedule_beat(state.bpm)
    {:noreply, %{state | beat: state.beat + 1}}
  end

  defp schedule_beat(bpm) do
    ms_per_beat = div(60_000, bpm)
    Process.send_after(self(), :beat, ms_per_beat)
  end
end
```

### Step 3: Create Supervisor

**File: `lib/extensions/music/supervisor.ex`**
```elixir
defmodule Realtime.Music.Supervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(name: __MODULE__, strategy: :one_for_one)
  end

  def start_tempo_server(room_id, bpm) do
    spec = {Realtime.Music.TempoServer, {room_id, bpm}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
```

### Step 4: Register Extension

**In `config/config.exs`:**
```elixir
config :realtime, :extensions,
  music: %{
    supervisor: Realtime.Music.Supervisor,
    key: "music"
  }
```

### Step 5: Use in Channel

**In `lib/realtime_web/channels/realtime_channel.ex`** (or create custom channel):

```elixir
def handle_in("set_tempo", %{"bpm" => bpm}, socket) do
  room_id = extract_room_id(socket.assigns.channel_name)
  
  # Start tempo server if not exists
  Realtime.Music.Supervisor.start_tempo_server(room_id, bpm)
  
  # Broadcast tempo change
  broadcast!(socket, "tempo_changed", %{bpm: bpm})
  {:noreply, socket}
end
```

---

## Testing Locally

### 1. Start Server

```bash
# Install dependencies
mix deps.get

# Start database (if using docker-compose)
docker-compose up -d

# Run migrations
mix ecto.migrate

# Start server
mix phx.server
```

### 2. Connect Client

```javascript
// Using Supabase JS client
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'http://localhost:4000',
  'your-jwt-token'
)

// Join music room channel
const channel = supabase.channel('music_room:ABC123')

channel
  .on('broadcast', { event: 'play_note' }, (payload) => {
    console.log('Note played:', payload)
  })
  .on('broadcast', { event: 'beat' }, (payload) => {
    console.log('Beat:', payload.beat)
  })
  .subscribe()

// Play a note
channel.send({
  type: 'broadcast',
  event: 'play_note',
  payload: { midi: 60, student_id: 'student-1' }
})
```

---

## Key Files to Understand

### 1. `lib/realtime/application.ex`
- **What:** Application startup, supervisor tree
- **Why:** Shows how everything is wired together
- **Key:** Extension supervisors are auto-started here

### 2. `lib/realtime_web/channels/user_socket.ex`
- **What:** WebSocket connection handler
- **Why:** Shows how tenants are identified, JWT is verified
- **Key:** Tenant lookup happens here

### 3. `lib/realtime_web/channels/realtime_channel.ex`
- **What:** Channel join/broadcast/presence logic
- **Why:** This is where you'll add music-specific handlers
- **Key:** `join/3`, `handle_in/3`, `handle_info/2` are the main callbacks

### 4. `lib/realtime/tenants/cache.ex`
- **What:** Tenant lookup and caching
- **Why:** Shows how tenants are stored and retrieved
- **Key:** Fast in-memory lookup by `external_id`

### 5. `lib/extensions/postgres_cdc_rls/`
- **What:** Example extension (Postgres Changes)
- **Why:** Shows how to structure an extension
- **Key:** Supervisor pattern, GenServer processes

---

## Common Patterns

### Pattern 1: Broadcast to Channel

```elixir
# In channel handler
broadcast!(socket, "event_name", %{data: "value"})

# Or via PubSub directly
Phoenix.PubSub.broadcast(
  Realtime.PubSub,
  "realtime:tenant:channel_name",
  {:event, payload}
)
```

### Pattern 2: Start GenServer for Room

```elixir
# In supervisor
DynamicSupervisor.start_child(
  Realtime.Music.Supervisor,
  {Realtime.Music.TempoServer, {room_id, bpm}}
)
```

### Pattern 3: Get Tenant from Socket

```elixir
# Socket already has tenant assigned
tenant_id = socket.assigns.tenant
```

### Pattern 4: Rate Limiting

```elixir
# Already built-in, but you can check:
RateCounter.get(socket.assigns.rate_counter)
```

---

## Debugging Tips

### 1. Check Logs

```bash
# Set log level in connection
channel.subscribe({ log_level: "info" })
```

### 2. Inspect Channel State

```elixir
# In channel handler
IO.inspect(socket.assigns, label: "Socket assigns")
```

### 3. Check PubSub Topics

```elixir
# See what's subscribed
Phoenix.PubSub.list(Realtime.PubSub, "realtime:tenant:channel")
```

### 4. Use Realtime Inspector

Visit `http://localhost:4000/inspector/new` to test channels visually.

---

## Next Steps

1. **Read the architecture guide:** `docs/CODEBASE_ARCHITECTURE.md`
2. **Explore the codebase:** Start with `lib/realtime_web/channels/realtime_channel.ex`
3. **Create your first extension:** Follow the music extension example above
4. **Test locally:** Use the Supabase JS client to test channels
5. **Add music features:** Tempo server, session management, teacher controls

---

## Questions to Answer

As you explore, try to answer:

1. **How does a client join a channel?**
   - Look at `RealtimeChannel.join/3`

2. **How are messages broadcast?**
   - Look at `BroadcastHandler.handle/2`

3. **How is presence tracked?**
   - Look at `PresenceHandler.handle/2`

4. **How are extensions started?**
   - Look at `Realtime.Application.extensions_supervisors/0`

5. **How are tenants identified?**
   - Look at `RealtimeWeb.UserSocket.connect/3`

---

## Resources

- **Elixir Getting Started**: https://elixir-lang.org/getting-started/introduction.html
- **Phoenix Channels**: https://hexdocs.pm/phoenix/channels.html
- **GenServer Guide**: https://hexdocs.pm/elixir/GenServer.html
- **Supabase Realtime Docs**: https://supabase.com/docs/guides/realtime

---

**Remember:** This is a brownfield project. You're extending existing, production-grade code. Take time to understand the patterns before adding new features.

