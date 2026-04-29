---
name: syncing-with-beads
description: Use when an approved plan needs to be mirrored to Beads issues, or when an implementer needs to claim/close work via bd. Honors the SUPERPOWERS_BEADS flag and is a no-op when bd is unavailable or disabled.
---

# Syncing With Beads

## Overview

Mirror superpowers plans into [Beads](https://github.com/gastownhall/beads) (`bd` CLI) so implementer subagents can pull work via `bd ready`, claim it atomically, and close it on success — keeping plan markdown checkboxes in sync with `bd` issue status.

This skill is the **only** place that calls `bd`. Other skills delegate here; they do not invoke `bd` directly. That keeps the integration in one auditable surface.

**Announce at start:** "I'm using the syncing-with-beads skill to mirror the plan to Beads."

**Critical principle:** Beads is a **runtime index**. Plan markdown is the **canonical artifact**. If they ever disagree, the plan markdown wins. The `reconcile` action exists to detect and surface disagreements, not to silently rewrite the plan.

## Feature flag

This skill is a no-op unless Beads is enabled. Precedence (first match wins):

1. `SUPERPOWERS_BEADS=0` → forced off
2. `SUPERPOWERS_BEADS=1` → forced on
3. `.beads/` directory exists in repo root → on
4. otherwise → off (legacy markdown-only flow)

Source `$BEADS_DETECT` (see "Resolving the script path" below) for the helpers `bd_available`, `bd_enabled`, `bd_prefix`. Direct invocation prints status:

```bash
"$BEADS_DETECT" status
```

When the flag is off, every action in this skill exits 0 with a single log line and no side effects. The legacy plan-only flow runs unchanged.

## Resolving the script path

The script entry point lives inside the superpowers plugin install — never at a path relative to the user's project. Resolve it once and reuse:

```bash
# Each harness exposes its plugin root via a different env var. Try them in
# order, then fall back to an explicit override the user can set.
SUPERPOWERS_ROOT="${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${SUPERPOWERS_ROOT:-}}}"
[[ -z "$SUPERPOWERS_ROOT" ]] && {
  echo "error: cannot find superpowers root — set SUPERPOWERS_ROOT or run from a supported harness" >&2
  exit 1
}
BEADS_SYNC="$SUPERPOWERS_ROOT/scripts/beads-sync.sh"
BEADS_DETECT="$SUPERPOWERS_ROOT/scripts/beads-detect.sh"
```

The same pattern is already used by `hooks/session-start` for harness detection — match it. For Codex, Gemini, OpenCode, and other harnesses without a documented plugin-root env var, the user should set `SUPERPOWERS_ROOT` explicitly to wherever the plugin is checked out.

## Bootstrap

If `bd_enabled` is true but no `.beads/` exists in the repo, the `export-plan` action will:

- **interactive shell** (`[[ -t 0 ]]`): prompt once "No `.beads/` in this repo. Initialize with prefix '<basename>'? (y/N)". On `y` runs `bd init --prefix <basename>`. On `n` falls back to markdown-only for this plan.
- **non-interactive** (subagent, scheduler, CI): logs a warning and falls back to markdown-only. Never hangs on prompts.

Default prefix = lowercased basename of `$PWD` with `_` and `-` stripped. Override with `BEADS_PREFIX=foo`.

## Hierarchy and dependencies

```
plan markdown                           Beads
─────────────                           ─────
# <Feature> Implementation Plan   <-->  epic   (label: superpowers:plan)
## Chunk N: <Name>                <-->  chore  (parent: epic)
### Task N: <Name>                <-->  task   (parent: chunk-chore)
```

- **Tasks within a chunk are parallel by default** (no inter-task `--deps`).
- **Chunks are sequential by default**: every task in chunk N+1 is blocked by every task in chunk N. This guarantees `bd ready` only surfaces work whose entire predecessor chunk is finished.
- **Per-task override**: a task body may include `**Deps:** Task X, Task Y` to *replace* the default sequential dep with explicit task references.
- Every issue carries `--external-ref file://<absolute-plan-path>#task-N` (or `#chunk-N`) so the bd issue links back to the source line.

## Sync model

> **The controller writes both.** During an SDD/executing-plans run, the same agent step that ticks the plan checkbox also calls `bd close`. They cannot drift mid-run.

For out-of-band changes (a human closes a `bd` issue manually, another tool edits the markdown), run `reconcile` on demand:

- If issue is `closed` and matching plan checkboxes are unchecked → tick them.
- If checkboxes are `[x]` and matching issue is open → `bd close` it.
- If both moved in opposite directions since the last sync → print the diff and exit non-zero. Do **not** auto-resolve.

We do not install git hooks or background watchers. Users who want auto-reconciliation on every commit can opt in by running `bd hooks install` in their repo.

## Actions

All actions are dispatched through `"$BEADS_SYNC" <action> [args]` (resolve `$BEADS_SYNC` per **Resolving the script path** above).

### `export-plan <plan-path>`

Validates the plan header, parses `## Chunk N: …` and `### Task N: …` sections (skipping content inside fenced code blocks), creates the epic + chore + task tree under the right parents, wires sequential chunk deps, and stamps `**Beads:** <epic-id>` into the plan after the `**Spec:**` line.

- **Idempotent:** if `**Beads:**` is already present, prints the existing epic id and exits 0 with no changes.
- **Validates:** refuses with a line-pointed error if the plan is missing `# <Feature> Implementation Plan` on line 1, or any of the required `**Goal:**`, `**Architecture:**`, `**Spec:**` lines.
- **Output:** echoes the epic id on stdout; logs progress on stderr.

Used by: `writing-plans` (after Self-Review), `executing-plans` (Step 1, if epic missing).

### `claim-next <epic-id>`

Echoes the next ready leaf task ID under the epic, or empty string if none. Filters `bd ready --parent <id>` to `issue_type == "task"` (epics and chores show up in `bd ready` otherwise) and sorts by `(priority, id)`.

The caller is expected to follow up with `bd update <id> --claim` to atomically transition to in_progress and assign. Splitting selection from claim lets the caller decide based on the candidate (e.g., abort if priority is wrong, dispatch a different implementer for high-priority items).

Used by: `subagent-driven-development`, `executing-plans`.

### `reconcile <plan-path>` _(implemented in T5)_

Walks every issue under the plan epic and the matching checkboxes in the plan markdown. Behavior described in **Sync model** above.

### `close <issue-id> <plan-path>` _(implemented in T5)_

Closes the issue (`bd close <id> --suggest-next`) **and** ticks the matching `- [ ]` checkboxes in the plan markdown. Convenience wrapper used by SDD/executing-plans so the controller doesn't have to do the dual write inline.

## bd command catalogue

The skill uses these `bd` commands. Drift means we should update both this list and the script.

| Command | Purpose |
|---|---|
| `bd init --prefix <name>` | Bootstrap a `.beads/` in a repo (interactive only). |
| `bd create --type epic\|chore\|task --title --description --parent --external-ref --labels --silent` | Create issues during `export-plan`. `--silent` returns just the ID. |
| `bd dep add <blocked> <blocker>` | Wire chunk-sequential deps. |
| `bd ready --parent <epic> --json` | Find claimable work. Filter to leaf tasks via jq (no `--type` flag on `bd ready`). |
| `bd update <id> --claim` | Atomic in_progress + assign (called by SDD controller, not this skill). |
| `bd update <id> --status blocked --notes <reason>` | Surface BLOCKED implementer status. |
| `bd close <id> --suggest-next` | Close on success. |
| `bd show <id> --json` | Returns an array; access `.[0].field` to read the issue object. |
| `bd list --json` | Used by `reconcile` to walk the plan epic's children. |

## When NOT to use this skill

- Brainstorming/spec stage — specs are markdown-only by design. They link back from the plan epic; no separate `bd` issue.
- General-purpose Beads workflows in user projects unrelated to a superpowers plan. Use `bd` directly.
- When plan markdown is being authored or revised — wait until self-review passes; the `**Beads:**` stamp should be applied to a finalized plan, not a draft.

## Failure modes

- `bd` not on PATH → log "Beads not installed; plan stays markdown-only" and exit 0.
- `bd init` fails (e.g., no permission) → log error and exit non-zero. Caller decides whether to abort the plan or continue markdown-only.
- Plan parsing fails → exit 2 with `<file>:<line>` pointer.
- Re-export of an already-mirrored plan → no-op, echoes existing epic id.
- Concurrent `bd` writers (e.g., user editing in another tab) → controller's mtime check on the plan file. On conflict, surface to the human partner; do not silently overwrite.
