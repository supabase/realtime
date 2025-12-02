#!/bin/bash
# Test tracker: suggests which tests to run based on changed files or phase
# Usage:
#   ./scripts/test_tracker.sh              # Show tests for changed files
#   ./scripts/test_tracker.sh phase 2      # Show tests for Phase 2
#   ./scripts/test_tracker.sh list         # List all test files by phase

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Test file mapping by phase (compatible with bash 3.2)
get_phase_tests() {
  case "$1" in
    0) echo "test/setup_verification_test.exs" ;;
    1) echo "test/extensions/music/supervisor_test.exs test/extensions/music/registry_test.exs test/extensions/music/tempo_server_test.exs test/extensions/music/session_manager_test.exs" ;;
    2) echo "test/extensions/music/tempo_server_test.exs" ;;
    3) echo "test/realtime_web/channels/music_room_channel_test.exs" ;;
    4) echo "test/extensions/music/session_manager_test.exs" ;;
    5) echo "test/extensions/music/teacher_controls_test.exs test/realtime_web/channels/music_room_channel_test.exs" ;;
    6) echo "test/extensions/music/sel_tracker_test.exs" ;;
    *) echo "" ;;
  esac
}

# Get test file for a source file
get_test_for_file() {
  local file="$1"
  
  # Check if it's a test file itself
  if [[ "$file" == test/* ]]; then
    echo "$file"
    return
  fi
  
  # Direct mappings
  case "$file" in
    lib/extensions/music/supervisor.ex) echo "test/extensions/music/supervisor_test.exs" ;;
    lib/extensions/music/registry.ex) echo "test/extensions/music/registry_test.exs" ;;
    lib/extensions/music/tempo_server.ex) echo "test/extensions/music/tempo_server_test.exs" ;;
    lib/extensions/music/session_manager.ex) echo "test/extensions/music/session_manager_test.exs" ;;
    lib/realtime_web/channels/music_room_channel.ex) echo "test/realtime_web/channels/music_room_channel_test.exs" ;;
    lib/extensions/music/teacher_controls.ex) echo "test/extensions/music/teacher_controls_test.exs" ;;
    lib/extensions/music/sel_tracker.ex) echo "test/extensions/music/sel_tracker_test.exs" ;;
    *)
      # Try to infer from path
      if [[ "$file" == lib/extensions/music/*.ex ]]; then
        local basename=$(basename "$file" .ex)
        echo "test/extensions/music/${basename}_test.exs"
      elif [[ "$file" == lib/realtime_web/channels/*_channel.ex ]]; then
        local basename=$(basename "$file" .ex)
        echo "test/realtime_web/channels/${basename}_test.exs"
      fi
      ;;
  esac
}

show_phase_tests() {
  local phase=$1
  local tests=$(get_phase_tests "$phase")
  
  if [ -z "$tests" ]; then
    echo "❌ Unknown phase: $phase"
    echo "Available phases: 0, 1, 2, 3, 4, 5, 6"
    exit 1
  fi
  
  echo "📋 Tests for Phase $phase:"
  echo ""
  for test_file in $tests; do
    if [ -f "$test_file" ]; then
      echo "  ✅ $test_file"
    else
      echo "  ⏳ $test_file (not created yet)"
    fi
  done
  echo ""
  echo "Run with:"
  echo "  mix test $tests"
}

show_changed_tests() {
  # Get changed files from git (staged + unstaged)
  local changed_files=$(git diff --name-only HEAD 2>/dev/null || echo "")
  local staged_files=$(git diff --cached --name-only 2>/dev/null || echo "")
  local all_files=$(echo -e "$changed_files\n$staged_files" | sort -u | grep -E "\.(ex|exs)$" || true)
  
  if [ -z "$all_files" ]; then
    echo "ℹ️  No changed files detected. Run 'git status' to check."
    exit 0
  fi
  
  echo "📝 Changed files:"
  echo "$all_files" | sed 's/^/  - /'
  echo ""
  
  local test_files=""
  local found=false
  
  while IFS= read -r file; do
    local test_file=$(get_test_for_file "$file")
    if [ -n "$test_file" ]; then
      test_files="$test_files $test_file"
      found=true
    fi
  done <<< "$all_files"
  
  if [ "$found" = false ]; then
    echo "⚠️  No specific tests found for changed files."
    echo "   Consider running: mix test test/extensions/music/"
    exit 0
  fi
  
  # Remove duplicates and format
  test_files=$(echo $test_files | tr ' ' '\n' | sort -u | tr '\n' ' ')
  
  echo "🧪 Suggested tests to run:"
  echo ""
  for test_file in $test_files; do
    if [ -f "$test_file" ]; then
      echo "  ✅ $test_file"
    else
      echo "  ⏳ $test_file (not found)"
    fi
  done
  echo ""
  echo "Run with:"
  echo "  mix test $test_files"
}

list_all_tests() {
  echo "📚 All test files by phase:"
  echo ""
  for phase in 0 1 2 3 4 5 6; do
    echo "Phase $phase:"
    local tests=$(get_phase_tests "$phase")
    for test_file in $tests; do
      if [ -f "$test_file" ]; then
        echo "  ✅ $test_file"
      else
        echo "  ⏳ $test_file"
      fi
    done
    echo ""
  done
}

# Main
case "${1:-changed}" in
  phase)
    if [ -z "$2" ]; then
      echo "Usage: $0 phase <number>"
      echo "Example: $0 phase 2"
      exit 1
    fi
    show_phase_tests "$2"
    ;;
  list)
    list_all_tests
    ;;
  changed|"")
    show_changed_tests
    ;;
  *)
    echo "Usage: $0 [phase <num>|list|changed]"
    echo ""
    echo "Commands:"
    echo "  (no args)  Show tests for changed files (default)"
    echo "  phase <n>  Show tests for specific phase"
    echo "  list       List all test files by phase"
    exit 1
    ;;
esac
