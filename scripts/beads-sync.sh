#!/usr/bin/env bash
#
# beads-sync.sh — sync superpowers plan markdown <-> Beads issues.
#
# Actions:
#   export-plan <plan-path>   Create epic+chunks+tasks tree; write **Beads:**
#                             header line into the plan. Idempotent on re-run.
#   reconcile  <plan-path>    Reconcile checkbox state <-> bd issue status.
#                             (Implemented in T5; this v1 stubs out.)
#   claim-next <epic-id>      Echo the next ready task ID under the epic
#                             (or empty string if none).
#   close <issue-id> <plan>   Close the issue + tick its matching checkbox(es)
#                             in the plan markdown.
#                             (Implemented in T5; this v1 stubs out.)
#
# All actions short-circuit silently when bd_enabled is false.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./beads-detect.sh
source "$SCRIPT_DIR/beads-detect.sh"

# --- shared helpers ---

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[beads-sync] $*" >&2; }

require_bd() {
  bd_available || die "bd not on PATH"
}

# --- plan parsing ---

# Emit TSV of structural headers in a plan, skipping content inside code
# fences. Columns: lineno  kind(chunk|task)  number  name
plan_outline() {
  local plan="$1"
  local in_fence=0 lineno=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$line" in
      '```'*) in_fence=$((1 - in_fence)); continue ;;
    esac
    (( in_fence == 1 )) && continue
    if [[ "$line" =~ ^"## Chunk "([0-9]+)": "(.*)$ ]]; then
      printf "%d\tchunk\t%s\t%s\n" "$lineno" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^"### Task "([0-9]+)": "(.*)$ ]]; then
      printf "%d\ttask\t%s\t%s\n" "$lineno" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$plan"
}

# Extract lines [start..end-1] of a file (1-indexed inclusive start, exclusive end).
slice_lines() {
  local file="$1" start="$2" end="$3"
  if [[ "$end" == "0" ]]; then
    sed -n "${start},\$p" "$file"
  else
    sed -n "${start},$((end - 1))p" "$file"
  fi
}

# Read **Deps:** Task N, Task M line out of a body slice and echo space-separated task numbers.
parse_deps_override() {
  local body="$1"
  echo "$body" | grep -m1 -oE '^\*\*Deps:\*\* .*' | sed -E 's/\*\*Deps:\*\* //; s/Task //g; s/,//g' || true
}

# Get **Beads:** epic-id from plan header (empty if absent).
plan_beads_id() {
  grep -m1 -oE '^\*\*Beads:\*\* [a-zA-Z0-9.-]+' "$1" 2>/dev/null | awk '{print $2}' || true
}

# Insert a **Beads:** <id> line right after the **Spec:** line.
inject_beads_header() {
  local plan="$1" epic_id="$2" tmp
  tmp=$(mktemp)
  awk -v id="$epic_id" '
    /^\*\*Spec:\*\* / && !done { print; print "**Beads:** " id; done=1; next }
    { print }
  ' "$plan" > "$tmp"
  if ! grep -q "^\\*\\*Beads:\\*\\* $epic_id$" "$tmp"; then
    rm -f "$tmp"
    die "failed to inject **Beads:** header (no **Spec:** line found?)"
  fi
  mv "$tmp" "$plan"
}

# --- export-plan ---

# Validate the plan has the mandatory header lines. Print line-pointed
# errors and exit 2 on failure.
validate_plan_header() {
  local plan="$1" first
  first=$(head -1 "$plan")
  if ! [[ "$first" =~ ^"# ".+" Implementation Plan"$ ]]; then
    die "$plan:1 expected '# <Feature> Implementation Plan' header"
  fi
  for field in Goal Architecture Spec; do
    if ! grep -qE "^\\*\\*${field}:\\*\\* " "$plan"; then
      die "$plan missing required '**${field}:**' line"
    fi
  done
}

action_export_plan() {
  local plan="${1:-}"
  [[ -n "$plan" ]] || die "usage: export-plan <plan-path>"
  [[ -f "$plan" ]] || die "$plan not found"
  bd_enabled || { log "Beads disabled; skipping export of $plan"; return 0; }
  require_bd

  local plan_abs title goal_line arch_line spec_line existing_epic
  plan_abs="$(realpath "$plan")"
  validate_plan_header "$plan"

  existing_epic=$(plan_beads_id "$plan")
  if [[ -n "$existing_epic" ]]; then
    log "plan already mirrored to epic $existing_epic; nothing to do"
    echo "$existing_epic"
    return 0
  fi

  title=$(head -1 "$plan" | sed -E 's/^# (.+) Implementation Plan$/\1/')
  goal_line=$(grep -m1 -E '^\*\*Goal:\*\* ' "$plan" | sed -E 's/^\*\*Goal:\*\* //')
  arch_line=$(grep -m1 -E '^\*\*Architecture:\*\* ' "$plan" | sed -E 's/^\*\*Architecture:\*\* //')
  spec_line=$(grep -m1 -E '^\*\*Spec:\*\* ' "$plan" | sed -E 's/^\*\*Spec:\*\* //')

  log "exporting plan: $title"

  # Build outline
  local outline
  outline=$(plan_outline "$plan")
  if [[ -z "$outline" ]]; then
    die "$plan has no '## Chunk N:' or '### Task N:' headers"
  fi

  # Compute end-line for each header (next header's lineno, or 0 = EOF).
  # We carry an extra column "end" via paste-into-awk.
  local outline_with_end
  outline_with_end=$(printf '%s\n' "$outline" | awk -F'\t' '
    { rows[NR] = $0; line[NR] = $1 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        end = (i < n) ? line[i+1] : 0
        print rows[i] "\t" end
      }
    }')

  # 1) Create the epic
  local epic_id epic_desc
  epic_desc=$(cat <<EOF
$goal_line

**Architecture:** $arch_line
**Plan file:** $plan_abs
**Spec:** $spec_line

\`\`\`json
{"plan":"$plan_abs","sha":"$(git -C "$(dirname "$plan_abs")" rev-parse --short HEAD 2>/dev/null || echo unknown)"}
\`\`\`
EOF
)
  epic_id=$(bd create \
    --type epic \
    --title "$title" \
    --description "$epic_desc" \
    --labels "superpowers:plan" \
    --external-ref "file://$plan_abs" \
    --silent 2>&1 | tail -1)
  log "created epic: $epic_id"

  # 2) Walk outline, create chunk chores and task issues, recording IDs.
  # task_ids_by_num: associative array task_num -> issue_id
  # tasks_by_chunk_idx: chunk_idx -> space-separated task_nums (in order)
  declare -A task_id_by_num=()
  declare -A task_body_by_num=()
  declare -A chunk_id_by_idx=()
  declare -A tasks_in_chunk=()

  local current_chunk_idx=0 current_chunk_id=""
  while IFS=$'\t' read -r lineno kind num name end; do
    local body
    body=$(slice_lines "$plan" "$((lineno + 1))" "$end")

    case "$kind" in
      chunk)
        current_chunk_idx=$((current_chunk_idx + 1))
        # Use just the leading paragraph as the chunk description (everything up to first task or a blank-line gap).
        local chunk_desc
        chunk_desc=$(printf '%s\n' "$body" | awk 'NR>1 && /^### Task / {exit} {print}')
        current_chunk_id=$(bd create \
          --type chore \
          --title "Chunk $num: $name" \
          --description "$chunk_desc" \
          --parent "$epic_id" \
          --external-ref "file://$plan_abs#chunk-$num" \
          --silent 2>&1 | tail -1)
        chunk_id_by_idx[$current_chunk_idx]="$current_chunk_id"
        tasks_in_chunk[$current_chunk_idx]=""
        log "  chunk $num ($name) -> $current_chunk_id"
        ;;
      task)
        [[ -n "$current_chunk_id" ]] || die "$plan task $num appears before any chunk"
        local task_id task_desc
        task_desc=$(printf '%s\n' "$body")
        task_id=$(bd create \
          --type task \
          --title "Task $num: $name" \
          --description "$task_desc" \
          --parent "$current_chunk_id" \
          --external-ref "file://$plan_abs#task-$num" \
          --silent 2>&1 | tail -1)
        task_id_by_num[$num]="$task_id"
        task_body_by_num[$num]="$body"
        tasks_in_chunk[$current_chunk_idx]="${tasks_in_chunk[$current_chunk_idx]} $num"
        log "    task $num ($name) -> $task_id"
        ;;
    esac
  done <<<"$outline_with_end"

  # 3) Wire dependencies.
  #    - Sequential chunks: every task in chunk N+1 depends on every task in chunk N.
  #    - Per-task **Deps:** override: replaces the default sequential set.
  local prev_idx=0
  for chunk_idx in $(printf '%s\n' "${!chunk_id_by_idx[@]}" | sort -n); do
    if (( prev_idx > 0 )); then
      local prev_task_ids=""
      for tn in ${tasks_in_chunk[$prev_idx]}; do
        prev_task_ids="$prev_task_ids ${task_id_by_num[$tn]}"
      done
      for tn in ${tasks_in_chunk[$chunk_idx]}; do
        local task_id="${task_id_by_num[$tn]}"
        local override
        override=$(parse_deps_override "${task_body_by_num[$tn]}")
        if [[ -n "$override" ]]; then
          for dep_num in $override; do
            local dep_id="${task_id_by_num[$dep_num]:-}"
            [[ -n "$dep_id" ]] || { log "warn: task $tn **Deps:** references unknown Task $dep_num"; continue; }
            bd dep add "$task_id" "$dep_id" >/dev/null
          done
        else
          for dep_id in $prev_task_ids; do
            bd dep add "$task_id" "$dep_id" >/dev/null
          done
        fi
      done
    else
      # First chunk: still honor explicit overrides (referencing earlier-numbered tasks).
      for tn in ${tasks_in_chunk[$chunk_idx]}; do
        local override
        override=$(parse_deps_override "${task_body_by_num[$tn]}")
        for dep_num in $override; do
          local dep_id="${task_id_by_num[$dep_num]:-}"
          [[ -n "$dep_id" ]] || { log "warn: task $tn **Deps:** references unknown Task $dep_num"; continue; }
          bd dep add "${task_id_by_num[$tn]}" "$dep_id" >/dev/null
        done
      done
    fi
    prev_idx=$chunk_idx
  done

  # 4) Stamp the plan file with **Beads:** <epic-id>.
  inject_beads_header "$plan" "$epic_id"
  log "stamped **Beads:** $epic_id into $plan"
  echo "$epic_id"
}

# --- claim-next (lightweight; needed by SDD wiring) ---

action_claim_next() {
  local epic_id="${1:-}"
  [[ -n "$epic_id" ]] || die "usage: claim-next <epic-id>"
  bd_enabled || { log "Beads disabled"; return 0; }
  require_bd
  # bd ready returns epics/chores/tasks; we only want leaf tasks. Sort by
  # priority asc then id (stable) and take the first.
  bd ready --parent "$epic_id" --json 2>/dev/null \
    | jq -r '[.[] | select(.issue_type == "task")] | sort_by(.priority, .id) | .[0].id // empty'
}

# --- reconcile / close (stubbed for v1; implemented in T5) ---

action_reconcile() {
  die "reconcile action not yet implemented (tracked as superpowers-4b0.5)"
}

action_close() {
  die "close action not yet implemented (tracked as superpowers-4b0.5)"
}

# --- entry point ---

usage() {
  cat <<EOF
beads-sync.sh — sync superpowers plans to Beads.

Usage:
  $0 export-plan <plan-path>     Create epic+chunks+tasks tree
  $0 claim-next  <epic-id>       Echo next ready task id
  $0 reconcile   <plan-path>     [stub] Reconcile checkbox <-> bd state
  $0 close       <id> <plan>     [stub] Close issue + tick checkbox

Honors SUPERPOWERS_BEADS env var and .beads/ directory presence.
See scripts/beads-detect.sh for flag precedence.
EOF
}

main() {
  local action="${1:-}"
  shift || true
  case "$action" in
    export-plan)  action_export_plan "$@" ;;
    claim-next)   action_claim_next "$@" ;;
    reconcile)    action_reconcile "$@" ;;
    close)        action_close "$@" ;;
    -h|--help|"") usage ;;
    *)            usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
