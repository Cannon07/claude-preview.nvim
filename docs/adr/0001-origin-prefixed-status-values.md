# Bash proposals are indicator-only, with origin-prefixed statuses

Some agents — observed first with GPT-class models in the Codex integration — route file edits through the `Bash` tool instead of structured `Edit`/`Write`/`MultiEdit` calls. The plugin cannot safely render a content preview for arbitrary shell: doing so would require either dry-running the command in a sandbox (expensive, unsafe) or snapshotting and re-inspecting around the agent's execution (intrusive, racy). Two decisions follow from that constraint:

1. **Bash proposals never produce a [preview](../../CONTEXT.md#preview).** They only update [change indicators](../../CONTEXT.md#indicator) in the registry, so the user at least sees in neo-tree that the file was touched. This is the "Tier 1" path in `bin/core-pre-tool.sh`. A future "Tier 2" with real content diffs is named but not committed to.
2. **Bash-origin statuses are prefixed** (`bash_modified`, `bash_created`). The registry is a flat `{path → status}` map shared across all in-flight proposals; the Bash post-tool needs to clear *only its own* markers without clobbering markers from a concurrent Edit/Write/ApplyPatch whose post-tool hasn't fired. The prefix lets it do `clear_by_statuses(["deleted", "bash_modified", "bash_created"])` instead of a blind path-keyed clear.

## Considered Options

For the indicator-only policy:

- **Dry-run the command in a sandbox to compute the proposed diff.** Rejected: arbitrary shell can read network, mutate global state, and consume real time. Not safe to run speculatively, and would block the agent on every Bash proposal.
- **Snapshot before + diff after the agent runs.** Rejected: requires hooking *both* pre and post around the actual write, and the diff would be shown after the agent has already committed — too late to be a preview in any meaningful sense.

For encoding origin in the registry:

- **Single status with a separate origin column** (`{path → {status, origin}}`). Rejected: doubles the shape of every entry to serve one call site.
- **Per-tool sub-registries.** Rejected: complicates the common-case lookup (rendering an indicator) for a problem only the post-tool clear has.

## Consequences

- New origins (e.g. a future LSP-driven write detector) follow the same convention: `<origin>_modified`, `<origin>_created`.
- Renderers must map prefixed statuses to the same indicator as their un-prefixed counterpart, or they'll silently miss change icons. Today this mapping is centralised in `lua/code-preview/neo_tree.lua`.
- The `deleted` status is intentionally un-prefixed: `rm` detection lives in the Bash core path but `*** Delete File:` patch directives produce the same status from a structured-tool path, so origin isn't a clean discriminator there.
- If we ever build Tier 2 (real content diffs for shell writes), Bash proposals would start producing previews and the indicator-only assumption would need revisiting — but the prefix convention would still hold for the period when both tiers coexist.
