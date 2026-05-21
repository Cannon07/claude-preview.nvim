#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook entry for OpenAI Codex CLI.
#
# After issue #47 phase 3, this shim does almost nothing: it discovers the
# running Neovim's socket and makes a single RPC call into the in-process
# orchestrator (lua/code-preview/pre_tool/init.lua), then prints whatever the
# orchestrator returns. The bash that used to translate Codex's
# {tool_name, cwd, tool_input} payload (and the apply_patch → ApplyPatch
# field move) now lives in lua/code-preview/pre_tool/normalisers.lua
# (codex entry).
#
# When Neovim is unreachable, the shim abstains: exit 0 with no stdout.
# Codex then falls back to its native ask-before-write loop as if the plugin
# weren't installed. See docs/adr/0005-core-handler-runs-in-process.md.

# No `set -e`: the shim is the boundary between the agent and the plugin.
# When jq fails on a malformed payload or nvim_call returns rc=2, we want
# to exit 0 (abstain) so the agent falls back to its native flow rather
# than seeing a hook failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"

INPUT="$(cat)"

# Fast-path filter for tools that never produce a preview. Codex hits hooks
# directly (no TS-side allowlist like opencode), so every tool firing —
# including the very chatty read/view/glob/grep/ls/list_files and MCP
# tools — would otherwise pay for socket discovery + an RPC round-trip just
# for the Lua normaliser to return tool_name=nil. The Lua map in
# pre_tool.normalisers remains the source of truth; this case is purely a
# perf filter.
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in
  ""|read|view|glob|grep|ls|list_files) exit 0 ;;
  mcp__*) exit 0 ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Socket discovery — silent failure is fine, we abstain below.
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

ARGS="$(jq -nc --argjson r "$INPUT" --arg b codex '[$r, $b]' 2>/dev/null || true)"
# Malformed payload (jq couldn't parse) — abstain silently.
[[ -z "$ARGS" ]] && exit 0
nvim_call code-preview.pre_tool handle "$ARGS"
