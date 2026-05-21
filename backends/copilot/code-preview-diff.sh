#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook entry for GitHub Copilot CLI.
#
# After issue #47 phase 3, this shim does almost nothing: it discovers the
# running Neovim's socket and makes a single RPC call into the in-process
# orchestrator (lua/code-preview/pre_tool/init.lua), then prints whatever the
# orchestrator returns. The bash that used to translate Copilot's
# {toolName, cwd, toolArgs} payload into the canonical hook shape now lives
# in lua/code-preview/pre_tool/normalisers.lua (copilot entry).
#
# When Neovim is unreachable, the shim abstains: exit 0 with no stdout.
# Copilot then falls back to its native flow as if the plugin weren't
# installed. See docs/adr/0005-core-handler-runs-in-process.md.

# No `set -e`: the shim is the boundary between the agent and the plugin.
# When jq fails on a malformed payload or nvim_call returns rc=2, we want
# to exit 0 (abstain) so the agent falls back to its native flow rather
# than seeing a hook failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"

INPUT="$(cat)"

# Fast-path filter for tools that never produce a preview. Copilot has no
# per-tool hook matcher and no TS-side allowlist (unlike Claude Code's
# settings.json and opencode's TS plugin), so every tool firing — including
# the very chatty view/glob/grep/ls/report_intent — would otherwise pay for
# socket discovery + an RPC round-trip just for the Lua normaliser to return
# tool_name=nil. The Lua map in pre_tool.normalisers remains the source of
# truth; this case is purely a perf filter.
TOOL="$(printf '%s' "$INPUT" | jq -r '.toolName // empty' 2>/dev/null || true)"
case "$TOOL" in
  ""|view|glob|grep|ls|report_intent) exit 0 ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Socket discovery — silent failure is fine, we abstain below.
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$BIN_DIR/nvim-call.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

ARGS="$(jq -nc --argjson r "$INPUT" --arg b copilot '[$r, $b]' 2>/dev/null || true)"
# Malformed payload (jq couldn't parse) — abstain silently.
[[ -z "$ARGS" ]] && exit 0
nvim_call code-preview.pre_tool handle "$ARGS"
