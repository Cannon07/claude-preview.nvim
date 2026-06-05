#!/usr/bin/env bash
# test_install.sh — OpenAI Codex CLI hook install/uninstall tests
#
# Codex reads hooks from .codex/hooks.json. Modern Codex enables hooks by
# default; only an explicit `[features] hooks = false` (or the legacy
# `codex_hooks = false`) silences them. Our installer writes hooks.json
# (merging with any existing entries) and warns only on explicit opt-out —
# it does NOT edit config.toml. These tests pin that contract.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

nvim_exec "vim.cmd('cd $TEST_PROJECT_DIR')"

HOOKS_FILE="$TEST_PROJECT_DIR/.codex/hooks.json"
CONFIG_FILE="$TEST_PROJECT_DIR/.codex/config.toml"

# Redirect the "global" config path used by feature_flag_state away from
# the user's real ~/.codex/config.toml so this test never touches it.
GLOBAL_CONFIG_FILE="$TEST_PROJECT_DIR/.fake-home-codex-config.toml"
nvim_exec "vim.env.CODE_PREVIEW_CODEX_GLOBAL_CONFIG = '$GLOBAL_CONFIG_FILE'"
rm -f "$GLOBAL_CONFIG_FILE"

# ── Test: Install writes the correct hook file ──────────────────

test_install_codex_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  assert_file_exists "$HOOKS_FILE" "hooks.json should be created" || return 1

  # Both hook events present and pointing at our adapter scripts
  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains "$content" "PreToolUse"            "should have PreToolUse hook"  || return 1
  assert_contains "$content" "PostToolUse"           "should have PostToolUse hook" || return 1
  assert_contains "$content" "hook-entry.sh"  "should reference the generic hook-entry shim" || return 1
  assert_contains "$content" "codex pre"      "PreToolUse should pass the pre event"  || return 1
  assert_contains "$content" "codex post"     "PostToolUse should pass the post event" || return 1

  # Exactly one entry per event after a fresh install.
  local pre_count post_count
  pre_count="$(jq '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "PreToolUse should have 1 entry"  || return 1
  assert_eq "1" "$post_count" "PostToolUse should have 1 entry" || return 1
}

# ── Test: Install is idempotent ─────────────────────────────────

# Re-running install must not append duplicate entries — `is_installed()`
# uses our adapter path as the marker, and we filter them out before
# inserting on every install.
test_install_idempotent() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  nvim_exec "require('code-preview.backends.codex').install()"
  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  local pre_count post_count
  pre_count="$(jq '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "PreToolUse should still have 1 entry after re-install"  || return 1
  assert_eq "1" "$post_count" "PostToolUse should still have 1 entry after re-install" || return 1
}

# ── Test: Install preserves user-authored hook entries ──────────

# Codex supports stacking multiple hooks per event. A user might have their
# own logging or policy hook alongside ours. Install must merge, not stomp.
test_install_preserves_user_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"

  # User-authored hooks.json with unrelated commands in BOTH PreToolUse and
  # PostToolUse — install must preserve user entries on both events.
  cat > "$HOOKS_FILE" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-pre-policy" } ] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-post-policy" } ] }
    ]
  }
}
EOF

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  # Both user entries must survive.
  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains "$content" "user-pre-policy"  "user PreToolUse entry should survive install"  || return 1
  assert_contains "$content" "user-post-policy" "user PostToolUse entry should survive install" || return 1

  # Both ours and theirs should be present in PreToolUse and PostToolUse.
  local pre_count post_count
  pre_count="$(jq  '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "2" "$pre_count"  "PreToolUse should now have 2 entries (user + ours)"  || return 1
  assert_eq "2" "$post_count" "PostToolUse should now have 2 entries (user + ours)" || return 1
}

# ── Test: Uninstall removes only our entries ────────────────────

test_uninstall_preserves_user_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"

  cat > "$HOOKS_FILE" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-policy" } ] }
    ]
  }
}
EOF

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.2
  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.2

  # File should still exist (we don't delete it — user may have other entries).
  assert_file_exists "$HOOKS_FILE" "hooks.json should not be deleted on uninstall" || return 1

  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains     "$content" "user-policy"    "user entry must survive uninstall" || return 1
  assert_not_contains "$content" "hook-entry.sh"  "our hooks must be removed"         || return 1
}

# ── Test: feature_flag_state reflects default-enabled semantics ──

# Drives the helper that :CodePreviewStatus and :checkhealth use to surface
# the Codex hooks feature flag. Modern Codex enables hooks by default — the
# only "off" state is an explicit 'hooks = false' (or legacy
# `codex_hooks = false`) under [features].
test_feature_flag_state() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  rm -f  "$GLOBAL_CONFIG_FILE"

  # Both project-local and global absent → default (enabled).
  local default_state
  default_state="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$default_state" "no config files should default to 'enabled'" || return 1

  # Project-local exists without any hooks setting → still default (enabled).
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  cat > "$CONFIG_FILE" <<'EOF'
approval_policy = "on-request"
EOF
  local no_opinion
  no_opinion="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$no_opinion" "config.toml without a hooks line should stay 'enabled' (default)" || return 1

  # Project-local explicitly enables via the canonical `hooks` key.
  cat > "$CONFIG_FILE" <<'EOF'
[features]
hooks = true
EOF
  local explicit_on
  explicit_on="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$explicit_on" "explicit 'hooks = true' should be 'enabled'" || return 1

  # Legacy alias `codex_hooks = true` must still parse as enabled.
  cat > "$CONFIG_FILE" <<'EOF'
[features]
codex_hooks = true
EOF
  local legacy_on
  legacy_on="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$legacy_on" "legacy 'codex_hooks = true' should be 'enabled'" || return 1

  # Explicit opt-out via canonical key → disabled.
  cat > "$CONFIG_FILE" <<'EOF'
[features]
hooks = false
EOF
  local explicit_off
  explicit_off="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$explicit_off" "explicit 'hooks = false' should be 'disabled'" || return 1

  # Explicit opt-out via legacy alias.
  cat > "$CONFIG_FILE" <<'EOF'
[features]
codex_hooks = false
EOF
  local legacy_off
  legacy_off="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$legacy_off" "legacy 'codex_hooks = false' should be 'disabled'" || return 1
}

# ── Test: project-local precedence over global config ───────────

# Codex reads ~/.codex/config.toml (global) in addition to .codex/config.toml
# (project-local). Project-local should override the global setting — a user
# who turned hooks off globally but back on for this project shouldn't see a
# false warning, and vice versa.
test_feature_flag_state_global() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  rm -f  "$GLOBAL_CONFIG_FILE"

  # Global disables, no project-local opinion → disabled propagates.
  cat > "$GLOBAL_CONFIG_FILE" <<'EOF'
[features]
hooks = false
EOF
  local global_off
  global_off="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$global_off" "global 'hooks = false' should propagate" || return 1

  # Project-local re-enables — must win over the global off.
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  cat > "$CONFIG_FILE" <<'EOF'
[features]
hooks = true
EOF
  local local_wins_on
  local_wins_on="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$local_wins_on" "project-local 'hooks = true' should override global off" || return 1

  # Inverse: global enabled, project-local explicitly disables.
  cat > "$GLOBAL_CONFIG_FILE" <<'EOF'
[features]
hooks = true
EOF
  cat > "$CONFIG_FILE" <<'EOF'
[features]
hooks = false
EOF
  local local_wins_off
  local_wins_off="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$local_wins_off" "project-local 'hooks = false' should override global on" || return 1
}

# ── Test: install refuses to overwrite a corrupted hooks.json ───

# Hand-edits or interrupted writes can leave hooks.json in an unparseable
# state. Silent overwrite would destroy whatever the user had. Install must
# bail with a clear error so the user can recover.
test_install_refuses_corrupted_hooks_json() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  # Garbage that can never decode as JSON.
  printf '%s\n' '{ this is not valid json at all' > "$HOOKS_FILE"

  local original_content
  original_content="$(cat "$HOOKS_FILE")"

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  # File contents must be unchanged.
  local after_content
  after_content="$(cat "$HOOKS_FILE")"
  assert_eq "$original_content" "$after_content" \
    "corrupted hooks.json must not be overwritten on install" || return 1

  # is_installed should still be false because we bailed.
  local installed
  installed="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$installed" "install should not register after bailing on corrupt JSON" || return 1
}

# ── Test: uninstall surfaces corrupted JSON instead of stomping ─

test_uninstall_handles_corrupted_hooks_json() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  printf '%s\n' '{ broken' > "$HOOKS_FILE"

  local original_content
  original_content="$(cat "$HOOKS_FILE")"

  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.3

  local after_content
  after_content="$(cat "$HOOKS_FILE")"
  assert_eq "$original_content" "$after_content" \
    "corrupted hooks.json must not be modified on uninstall" || return 1
}

# ── Test: is_installed reflects current hooks.json state ────────

test_is_installed_detection() {
  rm -rf "$TEST_PROJECT_DIR/.codex"

  local before
  before="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$before" "is_installed should be false when nothing is set up" || return 1

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.2
  local after
  after="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "true" "$after" "is_installed should be true after install" || return 1

  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.2
  local removed
  removed="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$removed" "is_installed should be false after uninstall" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Install Codex CLI hooks writes correct config"        test_install_codex_hooks
run_test "Install is idempotent (no duplicate entries)"         test_install_idempotent
run_test "Install preserves user-authored hook entries"         test_install_preserves_user_hooks
run_test "Uninstall preserves user-authored hook entries"       test_uninstall_preserves_user_hooks
run_test "feature_flag_state defaults to enabled; honors both keys/bools" test_feature_flag_state
run_test "feature_flag_state honors global ~/.codex/config.toml" test_feature_flag_state_global
run_test "Install refuses to overwrite corrupted hooks.json"     test_install_refuses_corrupted_hooks_json
run_test "Uninstall doesn't stomp corrupted hooks.json"          test_uninstall_handles_corrupted_hooks_json
run_test "is_installed reflects hooks.json state"               test_is_installed_detection

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
