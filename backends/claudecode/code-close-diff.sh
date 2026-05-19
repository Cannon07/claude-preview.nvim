#!/usr/bin/env bash
# code-close-diff.sh — PostToolUse hook entry for Claude Code.
#
# After issue #47 phase 3, this shim makes a single RPC call into the
# in-process orchestrator (lua/code-preview/post_tool.lua) and exits. The
# orchestrator clears the changes registry, closes any open preview for the
# affected file, and refreshes neo-tree.
#
# When Neovim is unreachable, the shim abstains silently (exit 0).

# No `set -e`: abstain on jq/nvim_call failure rather than surfacing a
# hook failure to the agent. See the matching note in code-preview-diff.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

ARGS="$(jq -nc --argjson r "$INPUT" --arg b claudecode '[$r, $b]' 2>/dev/null || true)"
[[ -z "$ARGS" ]] && exit 0
nvim_call code-preview.post_tool handle "$ARGS" >/dev/null
