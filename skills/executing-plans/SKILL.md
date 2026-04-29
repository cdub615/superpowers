---
name: executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load plan, review critically, execute all tasks, report when complete.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

**Note:** Tell your human partner that Superpowers works much better with access to subagents. The quality of its work will be significantly higher if run on a platform with subagent support (such as Claude Code or Codex). If subagents are available, use superpowers:subagent-driven-development instead of this skill.

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed

<!-- BEGIN beads -->
**If Beads is enabled** (`SUPERPOWERS_BEADS=1` or `.beads/` exists in repo root):
- Look for `**Beads:** <epic-id>` in the plan header.
- If present, capture the epic id for use in Step 2.
- If absent, dispatch `superpowers:syncing-with-beads`, action `export-plan <plan-path>` first — it creates the issue tree and stamps the header. Idempotent on re-run.
<!-- END beads -->

### Step 2: Execute Tasks

For each task:
1. Mark as in_progress
2. Follow each step exactly (plan has bite-sized steps)
3. Run verifications as specified
4. Mark as completed

<!-- BEGIN beads -->
**Beads-aware variant** (when Step 1 captured a `<epic-id>`): bracket each task with bd state changes. There is no implementer subagent in this skill, so the controller (you) is the sole writer of both Beads and TodoWrite/markdown — no race conditions to worry about.

| Plain step | Beads-aware step |
|---|---|
| Pick next task from plan order | Dispatch `superpowers:syncing-with-beads`, action `claim-next <epic-id>` → returns the next ready leaf task ID, or empty when done |
| Mark in_progress | `bd update <id> --claim` (atomic) **and** TodoWrite → in_progress |
| Run the task's steps | unchanged |
| Mark completed | Dispatch `superpowers:syncing-with-beads`, action `close <id> <plan-path>` (closes bd issue + ticks `[ ]` checkboxes for that `### Task N:`) **and** TodoWrite → completed |
| BLOCKED | `bd update <id> --status blocked --notes "<reason>"` before stopping |

When the flag is off, this section is a no-op and the legacy markdown-only flow runs unchanged.
<!-- END beads -->

### Step 3: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use superpowers:finishing-a-development-branch
- Follow that skill to verify tests, present options, execute choice

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **superpowers:using-git-worktrees** - Ensures isolated workspace (creates one or verifies existing)
- **superpowers:writing-plans** - Creates the plan this skill executes
- **superpowers:finishing-a-development-branch** - Complete development after all tasks
