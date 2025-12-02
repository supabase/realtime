# Elixir Idioms for Tenant ID Propagation

## Current Pattern in Codebase

**Socket Assigns (Phoenix Pattern)** - What Realtime already uses:
```elixir
# In UserSocket.connect/3
socket = socket |> assign(:tenant, external_id)

# In channel
tenant_id = socket.assigns.tenant  # Extract from socket
```

**Explicit Parameters** - Most idiomatic:
```elixir
def create_room(teacher_id, tenant_id, opts \\ [])
def get_tempo(room_id, tenant_id)
```

## Elixir Idioms (Ranked)

### 1. Explicit Parameters (Most Idiomatic) ✅
**Pros:** Clear, testable, no hidden state  
**Cons:** Verbose  
**When:** Always preferred

```elixir
# Good
def create_room(teacher_id, tenant_id, opts \\ [])
def get_tempo(room_id, tenant_id)
```

### 2. Socket Assigns (Phoenix-Specific) ✅
**Pros:** Built into Phoenix, flows through channels  
**Cons:** Only works in channel context  
**When:** In channels (already using this)

```elixir
# In channel
tenant_id = socket.assigns.tenant
```

### 3. Context Struct (For Complex State)
**Pros:** Groups related data, type-safe  
**Cons:** More boilerplate  
**When:** Multiple related values

```elixir
# Like Authorization struct in codebase
defstruct [:tenant_id, :topic, :claims, :role]
```

### 4. Process Dictionary (Discouraged) ❌
**Pros:** Convenient  
**Cons:** Hidden state, breaks encapsulation, not testable  
**When:** Never (except debugging)

```elixir
# Don't do this
Process.put(:tenant_id, tenant_id)
tenant_id = Process.get(:tenant_id)
```

## Recommendation

**For Music Extension:**
- **Channels:** Use `socket.assigns.tenant` (already available)
- **GenServers:** Pass `tenant_id` explicitly in state
- **Function calls:** Always pass `tenant_id` as parameter

**Why:** Matches existing codebase pattern, explicit is better than implicit.
