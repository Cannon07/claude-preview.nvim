#!/usr/bin/env bash
# test_install.sh — Claude Code hook install/uninstall tests

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# Change Neovim's cwd to the test project so backend module writes settings there
nvim_exec "vim.cmd('cd $TEST_PROJECT_DIR')"

# ── Test: Install Claude Code hooks ──────────────────────────────

test_install_claude_hooks() {
  nvim_exec "require('code-preview.backends.claudecode').install()"
  sleep 0.3

  local settings_file="$TEST_PROJECT_DIR/.claude/settings.local.json"
  assert_file_exists "$settings_file" "settings.local.json should be created" || return 1

  local content
  content="$(cat "$settings_file")"

  # Should have PreToolUse and PostToolUse hooks
  assert_contains "$content" "PreToolUse" "should have PreToolUse hook" || return 1
  assert_contains "$content" "PostToolUse" "should have PostToolUse hook" || return 1
  # One generic shim per OS, parameterized by backend + event (ADR-0008).
  assert_contains "$content" "hook-entry.sh" "should reference the generic hook-entry shim" || return 1
  assert_contains "$content" "claudecode pre" "PreToolUse should pass the pre event" || return 1
  assert_contains "$content" "claudecode post" "PostToolUse should pass the post event" || return 1
  # PowerShell is matched too: on Windows Claude Code routes shell file ops
  # (Remove-Item / Set-Content …) through a distinct PowerShell tool (issue #46
  # follow-up). The matcher is the same on every OS; the normaliser folds
  # PowerShell onto Bash.
  assert_contains "$content" "Edit|Write|MultiEdit|Bash|PowerShell" "should match Edit/Write/MultiEdit/Bash/PowerShell tools" || return 1
}

# ── Test: Uninstall Claude Code hooks ────────────────────────────

test_uninstall_claude_hooks() {
  # Install first
  nvim_exec "require('code-preview.backends.claudecode').install()"
  sleep 0.2

  # Then uninstall
  nvim_exec "require('code-preview.backends.claudecode').uninstall()"
  sleep 0.2

  local settings_file="$TEST_PROJECT_DIR/.claude/settings.local.json"
  assert_file_exists "$settings_file" "settings file should still exist" || return 1

  local content
  content="$(cat "$settings_file")"

  # Hook entries should be removed (empty arrays)
  assert_not_contains "$content" "hook-entry.sh" "hook-entry shim should be removed" || return 1
}

# ── Test: Install is idempotent (no duplicates) ─────────────────

test_install_idempotent() {
  nvim_exec "require('code-preview.backends.claudecode').install()"
  nvim_exec "require('code-preview.backends.claudecode').install()"
  sleep 0.2

  local settings_file="$TEST_PROJECT_DIR/.claude/settings.local.json"
  local content
  content="$(cat "$settings_file")"

  # Count PreToolUse entries (the pre event) — should be exactly 1.
  local count
  count="$(echo "$content" | grep -o "claudecode pre" | wc -l | tr -d ' ')"
  assert_eq "1" "$count" "should have exactly one PreToolUse hook entry" || return 1
}

# ── Test: Install preserves existing settings ────────────────────

test_install_preserves_existing() {
  # Write some pre-existing settings
  mkdir -p "$TEST_PROJECT_DIR/.claude"
  cat > "$TEST_PROJECT_DIR/.claude/settings.local.json" <<'JSON'
{
  "permissions": { "allow": ["Read"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "echo read" }] }
    ]
  }
}
JSON

  nvim_exec "require('code-preview.backends.claudecode').install()"
  sleep 0.2

  local content
  content="$(cat "$TEST_PROJECT_DIR/.claude/settings.local.json")"

  # Existing entries should be preserved
  assert_contains "$content" "permissions" "existing permissions should be preserved" || return 1
  assert_contains "$content" "echo read" "existing hook should be preserved" || return 1
  # Our hooks should also be present
  assert_contains "$content" "hook-entry.sh" "our hooks should be added" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Install Claude Code hooks writes correct settings" test_install_claude_hooks
run_test "Uninstall Claude Code hooks removes entries" test_uninstall_claude_hooks
run_test "Install is idempotent (no duplicate hooks)" test_install_idempotent
run_test "Install preserves existing settings" test_install_preserves_existing

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
