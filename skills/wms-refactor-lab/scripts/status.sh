#!/usr/bin/env bash
set -euo pipefail

DEFAULT_WMS="/Users/changjun/Desktop/cgkr_oncall"

if [ -n "${WMS_WORKSPACE:-}" ]; then
  TARGET_WORKSPACE="$WMS_WORKSPACE"
elif [ -d "$DEFAULT_WMS" ]; then
  TARGET_WORKSPACE="$DEFAULT_WMS"
else
  TARGET_WORKSPACE="$PWD"
fi

PANES_FILE="$TARGET_WORKSPACE/.omx/wms-refactor-lab/panes.env"
if [ ! -f "$PANES_FILE" ]; then
  echo "wms-refactor-lab is not registered for workspace: $TARGET_WORKSPACE"
  exit 0
fi

# shellcheck disable=SC1090
. "$PANES_FILE"

echo "wms-refactor-lab"
echo "workspace: ${WORKSPACE:-$TARGET_WORKSPACE}"
echo "tmux target: ${SESSION_WINDOW:-unknown}"
echo "leader: ${leader_pane:-unknown}"

print_pane() {
  local name="$1"
  local pane="$2"
  if [ -z "$pane" ]; then
    printf '%-18s missing\n' "$name"
    return
  fi
  if tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    local info
    info="$(tmux display-message -p -t "$pane" '#{pane_id} #{pane_current_path} #{pane_current_command}')"
    printf '%-18s %s\n' "$name" "$info"
  else
    printf '%-18s dead (%s)\n' "$name" "$pane"
  fi
}

print_pane "@coordinator" "${pane_coordinator:-}"
print_pane "@refactor-planner" "${pane_refactor_planner:-}"
print_pane "@plan-reviewer" "${pane_plan_reviewer:-}"
print_pane "@backend-developer" "${pane_backend_developer:-}"
print_pane "@fe-developer" "${pane_fe_developer:-}"
print_pane "@qa-reviewer" "${pane_qa_reviewer:-}"
