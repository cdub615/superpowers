#!/usr/bin/env bash
#
# beads-detect.sh — flag + availability helpers for the optional Beads
# integration. Sourced by skills/syncing-with-beads and downstream callers.
# Pure read-only checks; never mutates anything.
#
# Usage:
#   source scripts/beads-detect.sh
#   bd_available && bd_enabled && bd ready --json   # safe to call bd
#
# Direct invocation prints status (useful for smoke tests):
#   scripts/beads-detect.sh status

set -euo pipefail

# Returns 0 iff the `bd` binary is on PATH.
bd_available() {
  command -v bd >/dev/null 2>&1
}

# Returns 0 iff the Beads integration should be active in the current
# working directory. Precedence (first match wins):
#   1. SUPERPOWERS_BEADS=0  → forced off
#   2. SUPERPOWERS_BEADS=1  → forced on
#   3. .beads/ exists       → on (honors existing project state)
#   4. otherwise            → off (markdown-only legacy flow)
bd_enabled() {
  case "${SUPERPOWERS_BEADS:-}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  [[ -d .beads ]]
}

# Echoes the Beads prefix to use when initializing a new repo.
# BEADS_PREFIX env var wins; otherwise lowercased basename of $PWD with
# hyphens and underscores stripped (Beads prefix rules).
bd_prefix() {
  if [[ -n "${BEADS_PREFIX:-}" ]]; then
    printf '%s\n' "$BEADS_PREFIX"
    return
  fi
  basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -d '_-'
}

# Direct invocation: status report.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  case "${1:-status}" in
    status)
      if bd_available; then
        echo "bd_available: yes ($(command -v bd))"
      else
        echo "bd_available: no"
      fi
      if bd_enabled; then
        echo "bd_enabled:   yes"
      else
        echo "bd_enabled:   no"
      fi
      echo "bd_prefix:    $(bd_prefix)"
      ;;
    *)
      echo "usage: $0 [status]" >&2
      exit 1
      ;;
  esac
fi
