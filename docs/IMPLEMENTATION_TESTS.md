# Implementation Test Examples

This document contains high-value unit test examples for each phase of the music extension implementation. Reference these tests by phase/subphase as you implement features.

**Note:** These are example tests - adapt them to your specific implementation and add more as needed.

---

## Phase 0: Setup & Foundation

### Subphase 0.3: Development Workflow Setup

**File: `test/setup_verification_test.exs`**
```elixir
defmodule SetupVerificationTest do
  use ExUnit.Case
  
  test "application starts successfully" do
    # Verify application is running
    assert Process.whereis(Realtime.Supervisor) != nil
  end
  
  test "database connection works" do
    # Verify database is accessible
    assert {:ok, _} = Ecto.Adapters.SQL.query(Realtime.Repo, "SELECT 1", [])
  end
  
  test "existing tests pass" do
    # Run a known-good test
    assert true  # Placeholder - run actual test suite
  end
end
```

---

## Phase 1: Music Extension Foundation

### Subphase 1.1: Create Extension Directory Structure

**File: `test/extensions/music/supervisor_test.exs`**
```elixir
defmodule Realtime.Music.SupervisorTest do
  use ExUnit.Case
  
  test "supervisor starts on application start" do
    assert Process.whereis(Realtime.Music.Supervisor) != nil
  end
  
  test "supervisor is a DynamicSupervisor" do
    # Verify it's a DynamicSupervisor by checking children
    assert DynamicSupervisor.which_children(Realtime.Music.Supervisor) != :undefined
  end
  
  test "supervisor can be started manually" do
    # Test supervisor can be started (if not already running)
    {:ok, pid} = Realtime.Music.Supervisor.start_link([])
    assert Process.alive?(pid)
  end
end
```

### Subphase 1.2: Register Extension

**File: `test/extensions/music/registry_test.exs`**
```elixir
defmodule Realtime.Music.RegistryTest do
  use ExUnit.Case
  
  setup do
    # Ensure registry is started
    start_supervised!(Realtime.Music.Registry)
    :ok
  end
  
  test "registry exists and can register processes" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    Registry.register(Realtime.Music.Registry, {:test, "room-1"}, pid)
    
    assert Registry.lookup(Realtime.Music.Registry, {:test, "room-1"}) == [{pid, nil}]
  end
  
  test "registry can look up processes" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    Registry.register(Realtime.Music.Registry, {:tempo_server, "room-123"}, pid)
    
    assert [{^pid, nil}] = Registry.lookup(Realtime.Music.Registry, {:tempo_server, "room-123"})
  end
  
  test "registry returns empty list for non-existent key" do
    assert Registry.lookup(Realtime.Music.Registry, {:nonexistent, "key"}) == []
  end
end
```

### Subphase 1.3: Create Basic Module Structure

**File: `test/extensions/music/tempo_server_test.exs`** (Skeleton tests)
```elixir
defmodule Realtime.Music.TempoServerTest do
  use ExUnit.Case, async: true
  
  test "module exists" do
    assert Code.ensure_loaded?(Realtime.Music.TempoServer)
  end
  
  test "can get tempo (after Phase 2 implementation)" do
    # This will fail until Phase 2
    # {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server("test-room", 120)
    # assert {:ok, 120} = Realtime.Music.TempoServer.get_tempo("test-room")
  end
end
```

**File: `test/extensions/music/session_manager_test.exs`** (Skeleton tests)
```elixir
defmodule Realtime.Music.SessionManagerTest do
  use ExUnit.Case
  
  test "module exists" do
    assert Code.ensure_loaded?(Realtime.Music.SessionManager)
  end
  
  test "session manager is running" do
    assert Process.whereis(Realtime.Music.SessionManager) != nil
  end
end
```

---

## Phase 2: Tempo Server

### Subphase 2.1: Implement Core TempoServer Logic

**File: `test/extensions/music/tempo_server_test.exs`**
```elixir
defmodule Realtime.Music.TempoServerTest do
  use ExUnit.Case, async: true
  
  setup do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    {:ok, pid} = Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    {:ok, room_id: room_id, pid: pid}
  end
  
  test "starts with correct BPM", %{room_id: room_id} do
    assert {:ok, 120} = Realtime.Music.TempoServer.get_tempo(room_id)
  end
  
  test "can change tempo", %{room_id: room_id} do
    :ok = Realtime.Music.TempoServer.set_tempo(room_id, 140)
    assert {:ok, 140} = Realtime.Music.TempoServer.get_tempo(room_id)
  end
  
  test "broadcasts beat events", %{room_id: room_id} do
    # Subscribe to PubSub topic
    topic = "realtime:test-tenant:music_room:#{room_id}"
    Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
    
    # Start clock
    :ok = Realtime.Music.TempoServer.start_clock(room_id)
    
    # Wait for beat
    assert_receive {:beat, beat_number}, 600
    assert beat_number >= 0
    
    # Should receive more beats
    assert_receive {:beat, _}, 600
  end
  
  test "can start and stop clock", %{room_id: room_id} do
    :ok = Realtime.Music.TempoServer.start_clock(room_id)
    :ok = Realtime.Music.TempoServer.stop_clock(room_id)
    
    # Should not receive beats after stopping
    refute_receive {:beat, _}, 600
  end
  
  test "handles tempo changes while running", %{room_id: room_id} do
    topic = "realtime:test-tenant:music_room:#{room_id}"
    Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
    
    # Start with slow tempo
    :ok = Realtime.Music.TempoServer.set_tempo(room_id, 60)
    :ok = Realtime.Music.TempoServer.start_clock(room_id)
    
    # Wait for first beat (slow tempo = ~1000ms)
    assert_receive {:beat, _}, 1200
    
    # Change to fast tempo
    :ok = Realtime.Music.TempoServer.set_tempo(room_id, 180)
    
    # Should receive beats faster now (180 BPM = ~333ms per beat)
    assert_receive {:beat, _}, 400
  end
  
  test "validates BPM range", %{room_id: room_id} do
    # Too low
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, 0)
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, -10)
    
    # Too high
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, 300)
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, 500)
    
    # Valid range
    assert :ok = Realtime.Music.TempoServer.set_tempo(room_id, 1)
    assert :ok = Realtime.Music.TempoServer.set_tempo(room_id, 299)
  end
  
  test "beat counter increments", %{room_id: room_id} do
    topic = "realtime:test-tenant:music_room:#{room_id}"
    Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
    
    :ok = Realtime.Music.TempoServer.start_clock(room_id)
    
    # Receive first beat
    assert_receive {:beat, 0}, 600
    
    # Receive second beat
    assert_receive {:beat, 1}, 600
    
    # Receive third beat
    assert_receive {:beat, 2}, 600
  end
end
```

### Subphase 2.2: Add Supervisor Integration

**File: `test/extensions/music/supervisor_integration_test.exs`**
```elixir
defmodule Realtime.Music.SupervisorIntegrationTest do
  use ExUnit.Case
  
  test "can start tempo server via supervisor" do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    
    assert {:ok, pid} = Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    assert Process.alive?(pid)
    
    # Verify it's registered
    assert [{^pid, nil}] = Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id})
  end
  
  test "can stop tempo server via supervisor" do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    {:ok, pid} = Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    
    :ok = Realtime.Music.Supervisor.stop_tempo_server(room_id)
    
    # Wait a bit for process to terminate
    Process.sleep(100)
    
    assert Process.alive?(pid) == false
    assert Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id}) == []
  end
  
  test "returns error when stopping non-existent server" do
    assert {:error, :not_found} = Realtime.Music.Supervisor.stop_tempo_server("nonexistent-room")
  end
  
  test "supervisor restarts crashed tempo server" do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    {:ok, pid} = Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    
    # Kill the process
    Process.exit(pid, :kill)
    
    # Wait for supervisor to restart
    Process.sleep(200)
    
    # Should be restarted (new PID)
    [{new_pid, nil}] = Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id})
    assert new_pid != pid
    assert Process.alive?(new_pid)
  end
end
```

---

## Phase 3: Music Room Channel

### Subphase 3.1: Create Basic Channel Structure

**File: `test/realtime_web/channels/music_room_channel_test.exs`**
```elixir
defmodule RealtimeWeb.MusicRoomChannelTest do
  use RealtimeWeb.ChannelCase, async: true
  
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    
    # Create test room (after Phase 4)
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    {:ok, socket: socket, tenant: tenant, room_id: room_id}
  end
  
  test "student can join music room", %{socket: socket, room_id: room_id} do
    params = %{
      "student_id" => "student-1",
      "name" => "Alice",
      "role" => "student"
    }
    
    assert {:ok, reply, socket} = 
      subscribe_and_join(socket, "music_room:#{room_id}", params)
    
    assert reply.room_id == room_id
    assert socket.assigns.student_id == "student-1"
    assert socket.assigns.role == "student"
  end
  
  test "returns error for non-existent room", %{socket: socket} do
    params = %{
      "student_id" => "student-1",
      "role" => "student"
    }
    
    assert {:error, %{reason: "Room not found"}} = 
      subscribe_and_join(socket, "music_room:NONEXISTENT", params)
  end
end
```

### Subphase 3.2: Implement Note Broadcasting

**File: `test/realtime_web/channels/music_room_channel_note_test.exs`**
```elixir
defmodule RealtimeWeb.MusicRoomChannelNoteTest do
  use RealtimeWeb.ChannelCase, async: true
  
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    {:ok, _, socket} = subscribe_and_join(
      socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    {:ok, socket: socket, room_id: room_id}
  end
  
  test "student can play note", %{socket: socket} do
    push(socket, "play_note", %{"midi" => 60})
    
    assert_broadcast "student_note", %{
      midi: 60,
      student_id: "student-1"
    }
  end
  
  test "note broadcast includes timestamp", %{socket: socket} do
    push(socket, "play_note", %{"midi" => 60})
    
    assert_broadcast "student_note", payload
    assert Map.has_key?(payload, :timestamp)
    assert is_integer(payload.timestamp)
  end
  
  test "returns error for invalid note payload", %{socket: socket} do
    push(socket, "play_note", %{})
    
    assert_reply {:error, %{reason: "midi required"}}
  end
  
  test "multiple students can play notes", %{socket: socket1, room_id: room_id} do
    # Second student joins
    tenant = Containers.checkout_tenant(run_migrations: true)
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket2} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    {:ok, _, socket2} = subscribe_and_join(
      socket2,
      "music_room:#{room_id}",
      %{"student_id" => "student-2", "role" => "student"}
    )
    
    # Student 1 plays note
    push(socket1, "play_note", %{"midi" => 60})
    
    # Both should receive
    assert_broadcast "student_note", %{midi: 60, student_id: "student-1"}
    
    # Student 2 plays note
    push(socket2, "play_note", %{"midi" => 72})
    
    # Both should receive
    assert_broadcast "student_note", %{midi: 72, student_id: "student-2"}
  end
end
```

### Subphase 3.3: Integrate Tempo Server

**File: `test/realtime_web/channels/music_room_channel_tempo_test.exs`**
```elixir
defmodule RealtimeWeb.MusicRoomChannelTempoTest do
  use RealtimeWeb.ChannelCase, async: true
  
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 120)
    
    {:ok, socket: socket, tenant: tenant, room_id: room_id}
  end
  
  test "receives beat events from tempo server", %{socket: socket, room_id: room_id} do
    {:ok, _, socket} = subscribe_and_join(
      socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    # Should receive beat events
    assert_broadcast "beat", %{beat: beat_number}, 600
    assert is_integer(beat_number)
    
    # Should receive more beats
    assert_broadcast "beat", %{beat: _}, 600
  end
  
  test "tempo server starts when room is joined", %{socket: socket, room_id: room_id} do
    # Verify tempo server doesn't exist yet
    assert Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id}) == []
    
    # Join room (should start tempo server)
    {:ok, _, _socket} = subscribe_and_join(
      socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    # Verify tempo server is now running
    assert [{_pid, nil}] = Registry.lookup(Realtime.Music.Registry, {:tempo_server, room_id})
  end
end
```

### Subphase 3.4: Implement Teacher Controls

**File: `test/realtime_web/channels/music_room_channel_teacher_test.exs`**
```elixir
defmodule RealtimeWeb.MusicRoomChannelTeacherTest do
  use RealtimeWeb.ChannelCase, async: true
  
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 120)
    
    # Teacher socket
    teacher_jwt = Generators.generate_jwt_token(tenant)
    {:ok, teacher_socket} = connect(UserSocket, %{}, conn_opts(tenant, teacher_jwt))
    {:ok, _, teacher_socket} = subscribe_and_join(
      teacher_socket,
      "music_room:#{room_id}",
      %{"student_id" => "teacher-1", "role" => "teacher"}
    )
    
    # Student socket
    student_jwt = Generators.generate_jwt_token(tenant)
    {:ok, student_socket} = connect(UserSocket, %{}, conn_opts(tenant, student_jwt))
    {:ok, _, student_socket} = subscribe_and_join(
      student_socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    {:ok, teacher_socket: teacher_socket, student_socket: student_socket, room_id: room_id}
  end
  
  test "teacher can set tempo", %{teacher_socket: teacher_socket, room_id: room_id} do
    push(teacher_socket, "set_tempo", %{"bpm" => 140})
    
    assert_reply :ok
    assert_broadcast "tempo_changed", %{bpm: 140}
    
    # Verify tempo server was updated
    assert {:ok, 140} = Realtime.Music.TempoServer.get_tempo(room_id)
  end
  
  test "student cannot set tempo", %{student_socket: student_socket} do
    push(student_socket, "set_tempo", %{"bpm" => 140})
    
    assert_reply {:error, %{reason: "unauthorized"}}
  end
  
  test "student receives tempo change broadcast", %{teacher_socket: teacher_socket, student_socket: student_socket} do
    push(teacher_socket, "set_tempo", %{"bpm" => 160})
    
    # Teacher gets reply
    assert_reply :ok
    
    # Student receives broadcast
    assert_broadcast "tempo_changed", %{bpm: 160}
  end
  
  test "teacher can mute student", %{teacher_socket: teacher_socket} do
    push(teacher_socket, "mute_student", %{"student_id" => "student-1"})
    
    assert_reply :ok
    assert_broadcast "student_muted", %{student_id: "student-1"}
  end
  
  test "student cannot mute other students", %{student_socket: student_socket} do
    push(student_socket, "mute_student", %{"student_id" => "student-2"})
    
    assert_reply {:error, %{reason: "unauthorized"}}
  end
  
  test "teacher can assign beat to student", %{teacher_socket: teacher_socket} do
    push(teacher_socket, "assign_beat", %{"student_id" => "student-1", "beat" => 2})
    
    assert_reply :ok
    assert_broadcast "beat_assigned", %{student_id: "student-1", beat: 2}
  end
end
```

---

## Phase 4: Session Management

### Subphase 4.1: Implement Room Creation

**File: `test/extensions/music/session_manager_test.exs`**
```elixir
defmodule Realtime.Music.SessionManagerTest do
  use ExUnit.Case
  
  test "can create room" do
    assert {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    assert String.starts_with?(room_id, "MUSIC-")
  end
  
  test "creates room with custom BPM" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 140)
    
    assert {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert room.bpm == 140
  end
  
  test "creates room with default BPM" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    assert {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert room.bpm == 120  # Default
  end
  
  test "can get room after creation" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 140)
    
    assert {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert room.teacher_id == "teacher-1"
    assert room.bpm == 140
    assert is_integer(room.created_at)
  end
  
  test "creates tempo server when room is created" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 120)
    
    assert {:ok, 120} = Realtime.Music.TempoServer.get_tempo(room_id)
  end
  
  test "generates unique room IDs" do
    {:ok, room_id1} = Realtime.Music.SessionManager.create_room("teacher-1")
    {:ok, room_id2} = Realtime.Music.SessionManager.create_room("teacher-2")
    
    assert room_id1 != room_id2
  end
end
```

### Subphase 4.2: Implement Room Joining

**File: `test/extensions/music/session_manager_join_test.exs`**
```elixir
defmodule Realtime.Music.SessionManagerJoinTest do
  use ExUnit.Case
  
  test "can join room" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-1")
    
    {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert "student-1" in room.students
  end
  
  test "can join multiple students" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-1")
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-2")
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-3")
    
    {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert length(room.students) == 3
    assert "student-1" in room.students
    assert "student-2" in room.students
    assert "student-3" in room.students
  end
  
  test "returns error when joining non-existent room" do
    assert {:error, :not_found} = Realtime.Music.SessionManager.join_room("NONEXISTENT", "student-1")
  end
  
  test "does not duplicate students in room" do
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-1")
    :ok = Realtime.Music.SessionManager.join_room(room_id, "student-1")  # Join again
    
    {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    # Should only appear once
    assert Enum.count(room.students, &(&1 == "student-1")) == 1
  end
end
```

### Subphase 4.3: Integrate with Channel

**File: `test/integration/music_room_integration_test.exs`**
```elixir
defmodule MusicRoomIntegrationTest do
  use RealtimeWeb.ChannelCase
  
  test "full music room flow" do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    
    # 1. Teacher creates room
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1", bpm: 120)
    
    # 2. Teacher joins channel
    teacher_jwt = Generators.generate_jwt_token(tenant)
    {:ok, teacher_socket} = connect(UserSocket, %{}, conn_opts(tenant, teacher_jwt))
    {:ok, _, teacher_socket} = subscribe_and_join(
      teacher_socket,
      "music_room:#{room_id}",
      %{"student_id" => "teacher-1", "role" => "teacher"}
    )
    
    # 3. Student joins channel
    student_jwt = Generators.generate_jwt_token(tenant)
    {:ok, student_socket} = connect(UserSocket, %{}, conn_opts(tenant, student_jwt))
    {:ok, _, student_socket} = subscribe_and_join(
      student_socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    # 4. Teacher sets tempo
    push(teacher_socket, "set_tempo", %{"bpm" => 140})
    assert_reply :ok
    
    # 5. Student receives tempo change
    assert_broadcast "tempo_changed", %{bpm: 140}
    
    # 6. Student plays note
    push(student_socket, "play_note", %{"midi" => 60})
    
    # 7. Teacher receives note
    assert_broadcast "student_note", %{midi: 60, student_id: "student-1"}
    
    # 8. Both receive beats
    assert_broadcast "beat", %{beat: _}, 600
  end
  
  test "student is tracked when joining channel" do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    
    {:ok, room_id} = Realtime.Music.SessionManager.create_room("teacher-1")
    
    # Verify no students initially
    {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert room.students == []
    
    # Student joins channel
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    {:ok, _, _socket} = subscribe_and_join(
      socket,
      "music_room:#{room_id}",
      %{"student_id" => "student-1", "role" => "student"}
    )
    
    # Verify student is now in room
    {:ok, room} = Realtime.Music.SessionManager.get_room(room_id)
    assert "student-1" in room.students
  end
end
```

---

## Phase 5: Integration & Polish

### Subphase 5.1: Error Handling

**File: `test/extensions/music/error_handling_test.exs`**
```elixir
defmodule Realtime.Music.ErrorHandlingTest do
  use ExUnit.Case
  
  test "handles invalid BPM values" do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Realtime.Music.Supervisor.start_tempo_server(room_id, 120)
    
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, 0)
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, 300)
    assert {:error, :invalid_bpm} = Realtime.Music.TempoServer.set_tempo(room_id, -10)
  end
  
  test "handles room not found gracefully" do
    assert {:error, :not_found} = Realtime.Music.SessionManager.get_room("NONEXISTENT")
    assert {:error, :not_found} = Realtime.Music.SessionManager.join_room("NONEXISTENT", "student-1")
  end
  
  test "handles tempo server not found" do
    assert_raise GenServer.CallError, fn ->
      Realtime.Music.TempoServer.get_tempo("nonexistent-room")
    end
  end
end
```

---

## Phase 6: SEL Data Integration (Optional)

### Subphase 6.1: Create SEL Tracker Module

**File: `test/extensions/music/sel_tracker_test.exs`**
```elixir
defmodule Realtime.Music.SELTrackerTest do
  use ExUnit.Case
  
  # Tests for SEL data collection
  # To be implemented in Phase 6
  
  test "can log participation event" do
    # Realtime.Music.SELTracker.log_participation("room-1", "student-1", "note_played")
    # Verify event is stored
  end
  
  test "can log reflection" do
    # Realtime.Music.SELTracker.log_reflection("room-1", "student-1", %{...})
    # Verify reflection is stored
  end
end
```

---

## Running Tests

### Run All Tests
```bash
mix test
```

### Run Tests for Specific Phase
```bash
# Phase 1
mix test test/extensions/music/supervisor_test.exs
mix test test/extensions/music/registry_test.exs

# Phase 2
mix test test/extensions/music/tempo_server_test.exs

# Phase 3
mix test test/realtime_web/channels/music_room_channel_test.exs

# Phase 4
mix test test/extensions/music/session_manager_test.exs
```

### Run with Coverage
```bash
mix test --cover
```

### Watch Mode
```bash
mix test.watch test/extensions/music/tempo_server_test.exs
```

---

**Remember:** These are example tests. Adapt them to your implementation and add more tests as needed. Focus on testing critical paths and edge cases.

