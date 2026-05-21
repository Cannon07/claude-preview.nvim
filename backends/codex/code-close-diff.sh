#!/usr/bin/env bash
# code-close-diff.sh — PostToolUse hook entry for OpenAI Codex CLI.
#
# Single RPC into the in-process orchestrator (lua/code-preview/post_tool.lua).
# The orchestrator clears the changes registry, closes any open preview for
# the affected file, and refreshes neo-tree.
#
# When Neovim is unreachable, the shim abstains silently (exit 0).

# No `set -e`: abstain on jq/nvim_call failure rather than surfacing a
# hook failure to the agent. See the matching note in code-preview-diff.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"

INPUT="$(cat)"

# Fast-path filter — see the matching note in code-preview-diff.sh.
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in
  ""|read|view|glob|grep|ls|list_files) exit 0 ;;
  mcp__*) exit 0 ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

ARGS="$(jq -nc --argjson r "$INPUT" --arg b codex '[$r, $b]' 2>/dev/null || true)"
[[ -z "$ARGS" ]] && exit 0
nvim_call code-preview.post_tool handle "$ARGS" >/dev/null
