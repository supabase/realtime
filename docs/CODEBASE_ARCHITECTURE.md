# Supabase Realtime Codebase Architecture Guide

## Overview

This is **Supabase Realtime** - an Elixir/Phoenix server that provides real-time functionality over WebSockets. It's designed as a **multi-tenant** system where each tenant (project) can have multiple channels for real-time communication.

**Key Features:**
- **Broadcast**: Send ephemeral messages between clients
- **Presence**: Track and synchronize shared state (who's online, what they're doing)
- **Postgres Changes**: Listen to database changes in real-time

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Clients (WebSocket)                  │
│  Students/Teachers connect via WebSocket                │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ WebSocket Connection
                     │
┌────────────────────▼────────────────────────────────────┐
│              RealtimeWeb.UserSocket                      │
│  - Authenticates JWT token                               │
│  - Identifies tenant from hostname                       │
│  - Assigns tenant configuration to socket               │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Routes to Channel
                     │
┌────────────────────▼────────────────────────────────────┐
│         RealtimeWeb.RealtimeChannel                      │
│  - Handles channel joins ("realtime:channel_name")      │
│  - Manages broadcast/presence/postgres_changes           │
│  - One process per channel connection                    │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
┌──────────────┐ ┌──────────┐ ┌──────────────┐
│  Broadcast   │ │ Presence │ │ Postgres CDC │
│  Handler     │ │ Handler  │ │ Extension    │
└──────────────┘ └──────────┘ └──────────────┘
```

---

## Core Components

### 1. Application Startup (`lib/realtime/application.ex`)

**What it does:**
- Starts all supervisors and processes
- Sets up Phoenix PubSub for message broadcasting
- Initializes tenant cache
- Starts extension supervisors (like Postgres CDC)

**Key Supervisors:**
- `Phoenix.PubSub` - Message broadcasting system
- `Realtime.Tenants.Cache` - Caches tenant configurations
- `RealtimeWeb.Endpoint` - Phoenix web server
- Extension supervisors (Postgres CDC, etc.)

### 2. Tenant System (`lib/realtime/tenants/`)

**What is a Tenant?**
A tenant represents a **project/database** that uses Realtime. Each tenant has:
- Unique `external_id` (like "project-abc123")
- JWT secret for authentication
- Rate limits (max users, events per second, etc.)
- Extensions (Postgres CDC settings, etc.)

**How Tenants Work:**

1. **Tenant Lookup** (`lib/realtime/tenants/cache.ex`):
   - Tenants are cached in memory for fast access
   - Looked up by `external_id` from the hostname
   - Example: `realtime-dev.localhost:4000` → tenant `"realtime-dev"`

2. **Tenant Connection** (`lib/realtime/tenants/connect.ex`):
   - Each tenant gets a GenServer process that manages database connection
   - Handles migrations, replication setup, connection pooling
   - One connection process per tenant

3. **Tenant Storage**:
   - Stored in `_realtime.tenants` table in the main database
   - Configuration includes: JWT secret, rate limits, extensions

**Example Tenant:**
```elixir
%Tenant{
  external_id: "music-classroom-1",
  jwt_secret: "encrypted_secret",
  max_concurrent_users: 200,
  max_events_per_second: 100,
  extensions: [%{type: "postgres_cdc_rls", settings: %{...}}]
}
```

### 3. Socket Connection (`lib/realtime_web/channels/user_socket.ex`)

**What it does:**
- Handles WebSocket connection establishment
- Authenticates JWT token
- Identifies tenant from hostname
- Assigns tenant configuration to socket

**Connection Flow:**
1. Client connects: `ws://realtime-dev.localhost:4000/socket`
2. Extract hostname: `"realtime-dev.localhost"`
3. Lookup tenant: `"realtime-dev"` → get tenant config
4. Verify JWT token from connection params
5. Assign tenant config to socket

**Channel Routing:**
```elixir
channel "realtime:*", RealtimeChannel
```
- All channels matching `"realtime:*"` are handled by `RealtimeChannel`
- Example: `"realtime:music_room:ABC123"` → `RealtimeChannel`

### 4. Channel System (`lib/realtime_web/channels/realtime_channel.ex`)

**What is a Channel?**
A channel is a **topic** that clients subscribe to. Think of it like a chat room or event stream.

**Channel Topics:**
- Format: `"realtime:" <> sub_topic`
- Example: `"realtime:music_room:ABC123"`
- The `sub_topic` is `"music_room:ABC123"`

**Channel Join Flow:**

1. **Client sends join request:**
   ```javascript
   channel.subscribe({
     config: {
       broadcast: { self: false, ack: false },
       presence: { key: "student-1" },
       postgres_changes: [...]
     }
   })
   ```

2. **Server validates:**
   - Check rate limits (joins per second, max channels per client)
   - Verify JWT token
   - Check authorization policies (for private channels)
   - Validate join payload

3. **Subscribe to PubSub:**
   - Subscribe to tenant topic: `"realtime:tenant_id:channel_name"`
   - This is how messages are broadcast to all clients in the channel

4. **Start extensions:**
   - Postgres CDC: Subscribe to database changes
   - Presence: Initialize presence tracking

**Channel State:**
Each channel connection maintains state:
```elixir
%{
  tenant: "music-classroom-1",
  channel_name: "music_room:ABC123",
  tenant_topic: "realtime:music-classroom-1:music_room:ABC123",
  private?: false,
  presence_enabled?: true,
  policies: %{...}  # Authorization policies
}
```

### 5. Broadcast System

**What it does:**
Sends ephemeral messages from one client to all other clients in the same channel.

**How it works:**

1. **Client sends broadcast:**
   ```javascript
   channel.send({
     type: "broadcast",
     event: "play_note",
     payload: { midi: 60, student_id: 5 }
   })
   ```

2. **Server receives** (`handle_in("broadcast", payload, socket)`):
   - Validates payload
   - Checks rate limits
   - Publishes to PubSub topic

3. **PubSub broadcasts:**
   - Message published to: `"realtime:tenant_id:channel_name"`
   - All subscribed channel processes receive it

4. **Clients receive:**
   - Server pushes message to all connected clients
   - Clients handle via: `channel.on("broadcast", { event: "play_note" }, handler)`

**Broadcast Handler** (`lib/realtime_web/channels/realtime_channel/broadcast_handler.ex`):
- Handles broadcast logic
- For private channels: Stores messages in database for replay
- For public channels: Just broadcasts (no persistence)

### 6. Presence System

**What it does:**
Tracks and synchronizes shared state between clients (who's online, what they're doing).

**How it works:**

1. **Client tracks presence:**
   ```javascript
   channel.track({
     student_id: 5,
     name: "Alice",
     beat: 1,
     muted: false
   })
   ```

2. **Server receives** (`handle_in("presence", payload, socket)`):
   - Updates presence state
   - Merges with other clients' presence
   - Broadcasts merged state to all clients

3. **Presence sync:**
   - Server periodically syncs presence state
   - Clients receive: `channel.on("presence", { event: "sync" }, handler)`
   - Clients can get full state: `channel.presenceState()`

**Presence Handler** (`lib/realtime_web/channels/realtime_channel/presence_handler.ex`):
- Manages presence state per channel
- Handles join/leave events
- Merges presence from all clients

### 7. Postgres Changes (Extension)

**What it does:**
Listens to PostgreSQL database changes and sends them to authorized clients.

**How it works:**

1. **Client subscribes:**
   ```javascript
   channel.subscribe({
     config: {
       postgres_changes: [{
         event: "INSERT",
         schema: "public",
         table: "reflections"
       }]
     }
   })
   ```

2. **Server subscribes to Postgres replication:**
   - Uses PostgreSQL logical replication
   - Watches for changes to specified tables
   - Filters by RLS (Row Level Security) policies

3. **Database changes trigger events:**
   - INSERT/UPDATE/DELETE on subscribed tables
   - Server broadcasts to subscribed clients

**Postgres CDC Extension** (`lib/extensions/postgres_cdc_rls/`):
- Manages replication connections
- Handles subscription lifecycle
- Filters changes by authorization policies

---

## Extension System

### How Extensions Work

Extensions are **pluggable modules** that add functionality to Realtime. The main extension is Postgres CDC, but you can add your own.

**Extension Structure:**
```elixir
# lib/extensions/music/
#   ├── supervisor.ex          # Supervisor for extension processes
#   ├── tempo_server.ex        # Your custom GenServer
#   └── music_room.ex          # Your custom logic
```

**Registering Extensions:**

1. **In `config/config.exs`:**
   ```elixir
   config :realtime, :extensions,
     music: %{
       supervisor: Realtime.Music.Supervisor,
       key: "music",
       db_settings: Realtime.Music.DBSettings
     }
   ```

2. **Extension Supervisor** (`lib/realtime/application.ex`):
   - Automatically started by `extensions_supervisors/0`
   - Manages extension processes

---

## How to Extend for Music Education

Based on your docs, here's how to add music-specific features:

### 1. Create Music Extension

**File: `lib/extensions/music/supervisor.ex`**
```elixir
defmodule Realtime.Music.Supervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(
      name: __MODULE__,
      strategy: :one_for_one
    )
  end

  def start_tempo_server(room_id, bpm) do
    spec = {Realtime.Music.TempoServer, {room_id, bpm}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
```

### 2. Create Tempo Server

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

  defp via_tuple(room_id) do
    {:via, Registry, {Realtime.Music.Registry, {:tempo_server, room_id}}}
  end
end
```

### 3. Create Custom Channel (Optional)

You can create a custom channel for music rooms, or use the existing `RealtimeChannel` with custom event handlers.

**Option A: Use Existing Channel**
- Use `RealtimeChannel` with topic: `"realtime:music_room:ROOM_ID"`
- Handle custom events in `handle_in/3`
- Add music-specific logic in handlers

**Option B: Create Custom Channel**
```elixir
defmodule RealtimeWeb.MusicRoomChannel do
  use RealtimeWeb, :channel

  def join("music_room:" <> room_id, params, socket) do
    # Start tempo server for this room
    Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    
    # Join the underlying realtime channel
    RealtimeChannel.join("realtime:music_room:#{room_id}", params, socket)
  end

  def handle_in("play_note", %{"midi" => midi}, socket) do
    # Broadcast to all students
    broadcast!(socket, "student_note", %{
      midi: midi,
      student_id: socket.assigns.student_id,
      timestamp: System.system_time(:millisecond)
    })
    {:noreply, socket}
  end
end
```

### 4. Register Extension

**In `config/config.exs`:**
```elixir
config :realtime, :extensions,
  music: %{
    supervisor: Realtime.Music.Supervisor,
    key: "music"
  }
```

---

## Data Flow Examples

### Example 1: Student Plays Note

```
1. Student A presses key → Frontend sends:
   channel.send({
     type: "broadcast",
     event: "play_note",
     payload: { midi: 60, student_id: "student-1" }
   })

2. WebSocket → RealtimeChannel.handle_in("broadcast", ...)
   - Validates payload
   - Checks rate limits
   - Publishes to PubSub: "realtime:tenant:music_room:ABC123"

3. PubSub broadcasts to all subscribed channel processes
   - Student B's channel process receives message
   - Student C's channel process receives message
   - Teacher's channel process receives message

4. Each channel process pushes to client:
   push(socket, "broadcast", %{
     event: "play_note",
     payload: { midi: 60, student_id: "student-1" }
   })

5. Clients receive and play note
```

### Example 2: Tempo Clock Beat

```
1. TempoServer sends beat event:
   Process.send_after(self(), :beat, 500)  # 120 BPM = 500ms

2. TempoServer.handle_info(:beat, state):
   - Broadcasts to PubSub: "realtime:tenant:music_room:ABC123"
   - Schedules next beat

3. All channel processes receive beat event
   - Push to clients: push(socket, "broadcast", {:beat, beat_number})

4. Clients receive beat and update metronome
```

### Example 3: Teacher Changes Tempo

```
1. Teacher sends tempo change:
   channel.send({
     type: "broadcast",
     event: "set_tempo",
     payload: { bpm: 140 }
   })

2. Server receives (could add custom handler):
   def handle_in("set_tempo", %{"bpm" => bpm}, socket) do
     if is_teacher?(socket) do
       # Update tempo server
       Realtime.Music.TempoServer.set_tempo(room_id, bpm)
       
       # Broadcast to all students
       broadcast!(socket, "tempo_changed", %{bpm: bpm})
     end
   end

3. TempoServer updates BPM and reschedules beats
4. All clients receive tempo change
```

---

## Key Concepts

### 1. Processes and Concurrency

**Elixir uses lightweight processes:**
- Each channel connection = one Elixir process
- Each tenant connection = one GenServer process
- Each tempo server = one GenServer process
- Processes are isolated (fault-tolerant)

**Example:**
- 20 students in a room = 20 channel processes
- 1 teacher = 1 channel process
- 1 tempo server = 1 GenServer process
- Total: 22 processes (all running concurrently)

### 2. PubSub (Publish-Subscribe)

**Phoenix PubSub** is the message broadcasting system:
- Channels subscribe to topics: `"realtime:tenant:channel_name"`
- Messages published to topics are received by all subscribers
- Enables broadcasting to multiple clients

**Topic Format:**
```elixir
Tenants.tenant_topic(tenant_id, channel_name, public?)
# => "realtime:tenant_id:channel_name"
```

### 3. Rate Limiting

**Built-in rate limiting:**
- Per-tenant limits (max users, events per second, etc.)
- Per-channel rate counters
- Prevents abuse

**Rate Limiters:**
- `Realtime.RateCounter` - Tracks events per second
- `Realtime.UsersCounter` - Tracks concurrent users
- `RealtimeWeb.TenantRateLimiters` - Tenant-level limits

### 4. Authorization

**For private channels:**
- Uses PostgreSQL Row Level Security (RLS)
- Policies checked on database connection
- Only authorized users can join/read

**Authorization Flow:**
1. Client provides JWT token
2. Server extracts claims (role, sub, etc.)
3. Server queries database with RLS policies
4. Policies determine if user can access channel

---

## Database Schema

### Main Database (`_realtime` schema)

**Tenants Table:**
```sql
CREATE TABLE _realtime.tenants (
  id UUID PRIMARY KEY,
  external_id TEXT UNIQUE,
  jwt_secret TEXT,
  max_concurrent_users INTEGER,
  max_events_per_second INTEGER,
  ...
);
```

**Extensions Table:**
```sql
CREATE TABLE _realtime.extensions (
  id UUID PRIMARY KEY,
  tenant_external_id TEXT REFERENCES tenants(external_id),
  type TEXT,  -- "postgres_cdc_rls", "music", etc.
  settings JSONB
);
```

### Tenant Database

Each tenant has its own database where:
- User data is stored
- RLS policies are defined
- Tables are watched for changes (Postgres CDC)

---

## Testing Your Extensions

### Test Channel Joins

```elixir
defmodule RealtimeWeb.MusicRoomChannelTest do
  use RealtimeWeb.ChannelCase

  test "student can join music room" do
    {:ok, _, socket} = socket("student:1", %{})
      |> subscribe_and_join(MusicRoomChannel, "music_room:ABC123", %{
        "student_id" => "student-1",
        "role" => "student"
      })
    
    assert socket.assigns.room_id == "ABC123"
  end
end
```

### Test Broadcasts

```elixir
test "note broadcast works" do
  {:ok, _, socket} = subscribe_and_join(...)
  
  push(socket, "play_note", %{"midi" => 60})
  assert_broadcast "student_note", %{midi: 60}
end
```

---

## Deployment Considerations

### Environment Variables

Key variables for music extensions:
- `PORT` - WebSocket port
- `DB_HOST` - Main database host
- `API_JWT_SECRET` - Secret for tenant management
- `MAX_CONNECTIONS` - Max WebSocket connections

### Scaling

**Horizontal Scaling:**
- Multiple Realtime nodes can run in a cluster
- Uses `libcluster` for node discovery
- PubSub messages distributed across nodes

**Vertical Scaling:**
- Each node can handle 250k+ connections
- For 20 students per classroom, one node can handle thousands of classrooms

---

## Next Steps for Music Extension

1. **Create extension structure:**
   - `lib/extensions/music/` directory
   - Supervisor, TempoServer, SessionManager modules

2. **Register extension:**
   - Add to `config/config.exs`
   - Extension will auto-start

3. **Create custom channel (optional):**
   - Or extend `RealtimeChannel` with music handlers

4. **Add database tables (if needed):**
   - For session management, SEL data, etc.
   - Use tenant database migrations

5. **Test thoroughly:**
   - Channel joins, broadcasts, tempo changes
   - Rate limiting, error handling

---

## Resources

- **Phoenix Channels Guide**: https://hexdocs.pm/phoenix/channels.html
- **GenServer Guide**: https://hexdocs.pm/elixir/GenServer.html
- **Phoenix PubSub**: https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html
- **Supabase Realtime Docs**: https://supabase.com/docs/guides/realtime

---

This architecture enables you to build real-time collaborative music games with:
- Low latency (< 100ms)
- High concurrency (20+ students per room)
- Fault tolerance (isolated processes)
- Scalability (horizontal + vertical)

The extension system allows you to add music-specific features while leveraging the existing real-time infrastructure.

