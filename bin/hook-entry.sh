#!/usr/bin/env bash
# hook-entry.sh — generic per-OS hook entry, parameterized by backend + event.
#
# Replaces the per-backend backends/<agent>/code-{preview,close}-diff.sh shims:
# post-#47 they were near-identical, differing only in data (backend name, the
# pre/post event, and a fast-path tool filter). One shim per OS, parameterized,
# scales 2→2 as agents are added instead of 2-per-agent. See ADR-0008.
#
# Usage (written into the agent's hook config by the installer):
#   hook-entry.sh <backend> <pre|post>
#
# Reads the agent's hook payload on stdin, optionally fast-path-filters noisy
# tools, discovers the running Neovim, and makes a single RPC into the in-process
# orchestrator. Abstains (exit 0, no stdout) when Neovim is unreachable, so the
# agent falls back to its native flow. See ADR-0005.

# No `set -e`: the shim is the boundary between the agent and the plugin — on any
# failure (bad payload, unreachable nvim) we exit 0 (abstain) rather than surface
# a hook error.
set -uo pipefail

BACKEND="${1:-}"
EVENT="${2:-}"

# hook-entry.sh lives in bin/ alongside nvim-socket.sh / nvim-call.sh.
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="$(cat)"

# Per-backend fast-path filter — skip tools that never produce a preview before
# paying for socket discovery + an RPC round-trip. The Lua normaliser remains the
# source of truth; this is purely a perf gate. Only codex/copilot need it:
# claudecode filters via its settings.json matcher, opencode via its TS allowlist.
case "$BACKEND" in
  codex)
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
    case "$TOOL" in
      ""|read|view|glob|grep|ls|list_files) exit 0 ;;
      mcp__*) exit 0 ;;
    esac
    ;;
  copilot)
    TOOL="$(printf '%s' "$INPUT" | jq -r '.toolName // empty' 2>/dev/null || true)"
    case "$TOOL" in
      ""|view|glob|grep|ls|report_intent) exit 0 ;;
    esac
    ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Socket discovery — silent failure is fine, we abstain below.
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

# Splice the raw payload verbatim into the RPC args array [payload, backend] —
# never re-serialise it. Malformed payload (jq fails) → abstain.
ARGS="$(jq -nc --argjson r "$INPUT" --arg b "$BACKEND" '[$r, $b]' 2>/dev/null || true)"
[[ -z "$ARGS" ]] && exit 0

case "$EVENT" in
  pre)  nvim_call code-preview.pre_tool  handle "$ARGS" ;;
  post) nvim_call code-preview.post_tool handle "$ARGS" >/dev/null ;;
esac
