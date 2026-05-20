#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook entry for OpenCode.
#
# After issue #47 phase 3, this shim is a thin wrapper around a single RPC
# into the in-process orchestrator (lua/code-preview/pre_tool/init.lua). The
# TS plugin (backends/opencode/index.ts) collects OpenCode's {tool, args,
# directory} into a JSON payload, pipes it to this shim, and awaits the
# result. Lua-side normalisation maps the camelCase/lowercase shape into the
# canonical form. See docs/adr/0006-opencode-defers-os-independence-to-46.md.
#
# When Neovim is unreachable, the shim abstains silently (exit 0).

# No `set -e`: the shim is the boundary between the agent and the plugin.
# When jq fails on a malformed payload or nvim_call returns rc=2, we want
# to exit 0 (abstain) so the agent falls back to its native flow rather
# than seeing a hook failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Socket discovery — silent failure is fine, we abstain below.
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

ARGS="$(jq -nc --argjson r "$INPUT" --arg b opencode '[$r, $b]' 2>/dev/null || true)"
# Malformed payload (jq couldn't parse) — abstain silently.
[[ -z "$ARGS" ]] && exit 0
nvim_call code-preview.pre_tool handle "$ARGS"
