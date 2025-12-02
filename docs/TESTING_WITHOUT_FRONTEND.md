# Testing the Music Extension Without a Frontend

## Overview

This backend work creates a **real-time WebSocket API** that a frontend will consume. You can test ~80% of functionality without building a custom frontend application.

**What you're building:** A real-time server that handles:
- Music room creation and management
- Tempo clock (broadcasts beats to all students)
- Note broadcasting (students hear each other's notes)
- Teacher controls (tempo changes, muting, role assignment)

**What you can test:** All the real-time infrastructure and API functionality.

**What requires frontend:** Audio synthesis, visual UI, game mechanics.

---

## What You Can Test (Without Frontend)

### ✅ Fully Testable

1. **Room Creation & Management**
   - Create rooms via IEx or API
   - Generate join codes
   - Track students in rooms

2. **Tempo Clock**
   - Start/stop tempo servers
   - Change tempo
   - See beat events in console/logs

3. **Note Broadcasting**
   - Send notes via WebSocket
   - Receive notes from other clients
   - See messages in console

4. **Teacher Controls**
   - Set tempo (teacher only)
   - Mute students
   - Assign beats
   - Test authorization (students can't control)

5. **Session Management**
   - Join/leave rooms
   - Track presence
   - Room cleanup

### ❌ Requires Frontend

- Audio synthesis (Tone.js to actually play sounds)
- Visual UI (buttons, metronome display, game interface)
- Game mechanics (rhythm games, scoring, visual feedback)
- User experience (login screens, room selection UI)

---

## Testing Methods

### Method 1: IEx Console (Command Line)

**Best for:** Testing core logic, GenServers, state management

```elixir
# Start dev server with IEx
make dev

# In IEx console:

# Test SessionManager
iex> {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", "tenant-1", bpm: 120)
iex> {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)

# Test TempoServer
iex> {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server("room-123", 120, "tenant-1")
iex> Realtime.Music.TempoServer.start_clock("room-123", "tenant-1")

# Subscribe to PubSub to see beats
iex> tenant_topic = Realtime.Tenants.tenant_topic("tenant-1", "music_room:room-123", true)
iex> Phoenix.PubSub.subscribe(Realtime.PubSub, tenant_topic)
iex> receive do
...>   {:beat, beat_number} -> IO.puts("Beat: #{beat_number}")
...> after
...>   1000 -> IO.puts("No beat received")
...> end
```

**Pros:**
- Fast iteration
- Direct access to functions
- Good for debugging

**Cons:**
- No WebSocket testing
- Manual message handling

---

### Method 2: WebSocket Client (Browser Console)

**Best for:** Testing real-time channels, broadcasts, presence

**Using Supabase JS Client:**

```javascript
// In browser console (or Node.js with Supabase client)
import { createClient } from '@supabase/supabase-js'

// Connect to your local server
const supabase = createClient(
  'http://localhost:4000',
  'your-jwt-token'  // Generate via IEx or API
)

// Create/join a room (after Phase 4)
// First create room via API or IEx:
// {:ok, room_id} = SessionManager.create_room("teacher-1", "tenant-1")

const roomId = "MUSIC-1234"  // From room creation
const channel = supabase.channel(`music_room:${roomId}`)

// Listen to beats
channel.on('broadcast', { event: 'beat' }, ({ payload }) => {
  console.log('🎵 Beat:', payload.beat)
})

// Listen to notes
channel.on('broadcast', { event: 'student_note' }, ({ payload }) => {
  console.log('🎹 Note played:', payload.midi, 'by', payload.student_id)
})

// Listen to tempo changes
channel.on('broadcast', { event: 'tempo_changed' }, ({ payload }) => {
  console.log('⏱️ Tempo changed to', payload.bpm, 'BPM')
})

// Subscribe to channel
channel.subscribe((status) => {
  console.log('Channel status:', status)
  if (status === 'SUBSCRIBED') {
    console.log('✅ Connected to music room!')
  }
})

// Play a note
channel.send({
  type: 'broadcast',
  event: 'play_note',
  payload: { midi: 60, student_id: 'student-1' }
})

// Teacher: Change tempo
channel.send({
  type: 'broadcast',
  event: 'set_tempo',
  payload: { bpm: 140 }
})
```

**Using Raw WebSocket (Alternative):**

```javascript
// Connect to WebSocket
const ws = new WebSocket('ws://localhost:4000/socket/websocket?vsn=2.0.0&token=YOUR_JWT')

ws.onopen = () => {
  // Join channel
  ws.send(JSON.stringify({
    topic: "music_room:MUSIC-1234",
    event: "phx_join",
    payload: {
      config: {
        broadcast: { self: true },
        presence: { key: "student-1" }
      },
      student_id: "student-1",
      role: "student"
    },
    ref: "1"
  }))
}

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data)
  console.log('Received:', msg)
  
  if (msg.event === 'beat') {
    console.log('Beat:', msg.payload.beat)
  }
  
  if (msg.event === 'student_note') {
    console.log('Note:', msg.payload.midi)
  }
}
```

**Pros:**
- Real WebSocket testing
- See actual message flow
- Test multiple clients

**Cons:**
- Need to generate JWT tokens
- More setup required

---

### Method 3: Integration Tests

**Best for:** Automated testing, CI/CD, regression testing

See `docs/IMPLEMENTATION_TESTS.md` for comprehensive test examples.

**Example:**
```elixir
test "full music room flow" do
  # Create room
  {:ok, room_id} = SessionManager.create_room("teacher-1", "tenant-1")
  
  # Teacher joins
  {:ok, _, teacher_socket} = subscribe_and_join(teacher_socket, "music_room:#{room_id}", ...)
  
  # Student joins
  {:ok, _, student_socket} = subscribe_and_join(student_socket, "music_room:#{room_id}", ...)
  
  # Teacher sets tempo
  push(teacher_socket, "set_tempo", %{"bpm" => 140})
  assert_broadcast "tempo_changed", %{bpm: 140}
  
  # Student plays note
  push(student_socket, "play_note", %{"midi" => 60})
  assert_broadcast "student_note", %{midi: 60}
  
  # Both receive beats
  assert_broadcast "beat", %{beat: _}, 600
end
```

**Pros:**
- Automated
- Repeatable
- Catches regressions

**Cons:**
- Requires test setup
- Can be flaky with timing

---

### Method 4: WebSocket Testing Tools

**Tools:**
- **websocat** (CLI): `websocat ws://localhost:4000/socket/websocket`
- **Postman** (GUI): Can test WebSocket connections
- **wscat** (Node.js): `npx wscat -c ws://localhost:4000/socket/websocket`

**Example with websocat:**
```bash
# Install: brew install websocat (or cargo install websocat)

# Connect and send join message
echo '{"topic":"music_room:MUSIC-1234","event":"phx_join","payload":{},"ref":"1"}' | \
  websocat ws://localhost:4000/socket/websocket?vsn=2.0.0
```

---

## Testing Workflow

### Phase-by-Phase Testing

**Phase 1-2 (Foundation & Tempo Server):**
- ✅ Test in IEx: Supervisor starts, TempoServer runs
- ✅ Test PubSub: Subscribe to topic, see beats

**Phase 3 (Music Room Channel):**
- ✅ Test WebSocket: Join channel, send/receive messages
- ✅ Test authorization: Teacher vs student permissions

**Phase 4 (Session Management):**
- ✅ Test room creation: Generate codes, store state
- ✅ Test room joining: Track students

**Phase 5 (Integration):**
- ✅ Test full flow: Create room → Join → Play notes → Change tempo
- ✅ Test multiple clients: 2+ students in same room

---

## What Success Looks Like

### ✅ Backend is "Done" When:

1. **You can create a room** (IEx or API)
2. **You can join via WebSocket** (browser console or tool)
3. **You see beats arriving** (console logs show beat events)
4. **You can send notes** (one client sends, others receive)
5. **Teacher controls work** (teacher can set tempo, students can't)
6. **Multiple clients work** (2+ students in same room)

### 🎯 Ready for Frontend When:

- All backend features work via WebSocket
- Integration tests pass
- Documentation is complete
- API is stable (no breaking changes expected)

---

## Quick Test Checklist

After each phase, verify:

- [ ] **Phase 1**: Supervisor starts, modules load
- [ ] **Phase 2**: Tempo server broadcasts beats (see in PubSub)
- [ ] **Phase 3**: Can join channel, send/receive messages
- [ ] **Phase 4**: Can create room, join room, see state
- [ ] **Phase 5**: Full flow works end-to-end

---

## Example: Full Test Session

```bash
# Terminal 1: Start server
make dev

# Terminal 2: Create room (IEx)
iex> {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", "tenant-1")
# => {:ok, "MUSIC-1234"}

# Browser Console: Student 1 joins
const channel1 = supabase.channel('music_room:MUSIC-1234')
channel1.on('broadcast', { event: 'beat' }, ({ payload }) => console.log('Student 1: Beat', payload.beat))
channel1.on('broadcast', { event: 'student_note' }, ({ payload }) => console.log('Student 1: Note', payload.midi))
channel1.subscribe()

# Browser Console: Student 2 joins (new tab)
const channel2 = supabase.channel('music_room:MUSIC-1234')
channel2.on('broadcast', { event: 'beat' }, ({ payload }) => console.log('Student 2: Beat', payload.beat))
channel2.on('broadcast', { event: 'student_note' }, ({ payload }) => console.log('Student 2: Note', payload.midi))
channel2.subscribe()

# Student 1 plays note
channel1.send({ type: 'broadcast', event: 'play_note', payload: { midi: 60, student_id: 'student-1' } })
# Both students should see: "Note 60"

# Both students should see beats arriving every ~500ms (at 120 BPM)
```

---

## The Bottom Line

**You can validate the entire backend works** before building any frontend. The backend is a working API that:
- Accepts WebSocket connections
- Broadcasts real-time events
- Handles room management
- Enforces authorization

**The frontend will:**
- Connect to this same WebSocket API
- Display beats visually
- Play audio when notes arrive
- Provide UI for controls

**You're building the infrastructure first** - test it thoroughly, then the frontend is "just" connecting to your working API.

---

**Next Steps:**
1. Follow `docs/IMPLEMENTATION_PLAN.md` to build features
2. Use this guide to test each phase
3. Reference `docs/IMPLEMENTATION_TESTS.md` for test examples
4. Once backend works, frontend integration is straightforward

