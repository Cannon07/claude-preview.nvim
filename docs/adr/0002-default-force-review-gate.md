# Default to forcing the Claude Code review gate

For the Claude Code integration, the pre-tool hook emits `permissionDecision: "ask"` by default — forcing Claude Code to prompt the user on every edit, even when the user has configured permissive settings (bypass mode, allowlists). Users can opt out with `diff.defer_claude_permissions = true`, which suppresses the JSON output and lets Claude Code's own settings decide.

The reason: the plugin's value proposition is *previewing edits before they land*. If Claude Code is in bypass mode or has the edit allowlisted, the [review gate](../../CONTEXT.md#review-gate) never opens — the agent writes the file immediately and the preview appears alongside an already-committed change, which is worse than no preview at all (the user might assume the diff is pending when it isn't). Defaulting to a forced gate ensures the preview *means something*: there is a real accept/reject moment that lines up with what's on screen.

## Considered Options

- **Default = respect Claude Code's permission settings.** Rejected: users who installed the plugin specifically to get previews would silently lose them whenever Claude Code's settings let an edit through. Surprising and quiet, which is the worst kind of behaviour.
- **No config knob; always force the gate.** Rejected: a user who deliberately wants Claude Code's permission machinery to be authoritative (e.g. relying on a careful allowlist) has no escape hatch. The opt-out exists for that case.
- **Default = force, opt-out via config** *(chosen)*. Prioritises the plugin's core promise; lets advanced users disable when they understand the trade-off.

## Consequences

- A user who installs the plugin while running Claude Code in `--dangerously-skip-permissions` (or equivalent bypass) will start seeing prompts they previously avoided. This is intended: the plugin's preview only works if there's a gate to hold open. README and `:CodePreviewStatus` should make the override discoverable.
- Other agents (OpenCode, Codex, Copilot CLI) are not affected — their gate mechanism is owned by the agent itself, not by output the plugin emits.
- If a new agent is added where the plugin can choose between forcing and deferring (analogous to Claude Code), this ADR sets the precedent: default to forcing.
