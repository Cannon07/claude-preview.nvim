#!/usr/bin/env bash
# nvim-call.sh — Structured RPC into the running Neovim.
#
# Replaces nvim-send.sh's string-interpolated "build Lua source in bash"
# pattern. Args travel as a JSON array via a temp file; the receiving Lua
# decodes them with vim.json.decode and calls the target function. No user
# data ever enters a Lua source string, so escape_lua and its quoting
# footguns are gone.
#
# Usage:
#   source bin/nvim-call.sh
#   ARGS=$(jq -nc --arg p "$path" --arg s "deleted" '[$p, $s]')
#   nvim_call code-preview.changes set "$ARGS"
#
#   # Capturing a return value (function returns a string or table):
#   CTX=$(nvim_call code-preview.log state '[]')
#   echo "$CTX" | jq -r '.debug'
#
# Depends on nvim-socket.sh being sourced first (NVIM_SOCKET must be set).

# nvim_call MOD FN JSON_ARGS
# Returns:
#   0 on success
#   1 if no nvim socket is available
#   2 if the dispatch itself failed (bad JSON, missing module/function, etc.)
# Stdout is the function's return value: strings pass through, tables are
# JSON-encoded, nil becomes empty string. Dispatch failures are also logged
# inside nvim via log.error (vim.notify), so a silent rc=2 here is visible
# to the developer through the editor.
nvim_call() {
  local mod="$1" fn="$2" args="${3:-[]}"
  if [[ -z "${NVIM_SOCKET:-}" ]]; then
    return 1
  fi
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/code-preview-args.XXXXXX")"
  printf '%s' "$args" > "$tmp"
  # Only mod/fn/tmp — all controlled by us — get interpolated into Lua source.
  # User data flows through $tmp as JSON.
  nvim --server "$NVIM_SOCKET" --remote-expr \
    "luaeval(\"require('code-preview.rpc').dispatch('$mod', '$fn', '$tmp')\")" 2>/dev/null
  local rc=$?
  rm -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    return 2
  fi
  return 0
}
