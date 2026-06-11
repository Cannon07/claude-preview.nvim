#!/usr/bin/env bash
# test_retry.sh — Unit guard for the OpenCode plugin's spurious-timeout retry.
#
# The Windows libuv quirk (the first spawnSync after async work spuriously times
# out; issue #46) can't be reproduced on CI, so this drives retry_test.ts, which
# exercises runWithSpuriousRetry directly with an injected `run` that throws a
# fast ETIMEDOUT/SIGTERM. No nvim/socket needed — it's a pure unit guard against
# the retry being accidentally removed or narrowed.

# ── Check for tsx/bun ────────────────────────────────────────────

_OPENCODE_RUNNER=""
if command -v bun >/dev/null 2>&1; then
  _OPENCODE_RUNNER="bun"
elif command -v npx >/dev/null 2>&1; then
  _OPENCODE_RUNNER="npx tsx"
else
  echo -e "${YELLOW}  ⊘ Skipping OpenCode retry guard (neither bun nor npx found)${NC}"
  return 0 2>/dev/null || exit 0
fi

RETRY_TEST="$SCRIPT_DIR/backends/opencode/retry_test.ts"

# ── Test: retry helper recovers / is bounded ─────────────────────

test_opencode_retry_guard() {
  local output
  output="$($_OPENCODE_RUNNER "$RETRY_TEST" 2>&1)"
  if [[ "$output" != *"ALL OK"* ]]; then
    echo -e "  ${RED}retry guard output:${NC}" >&2
    echo "$output" >&2
    return 1
  fi
}

run_test "OpenCode retry recovers fast ETIMEDOUT/SIGTERM, bounded, no over-retry" test_opencode_retry_guard
