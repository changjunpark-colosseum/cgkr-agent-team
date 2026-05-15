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
  echo "No wms-refactor-lab pane registry found: $PANES_FILE"
  exit 0
fi

# shellcheck disable=SC1090
. "$PANES_FILE"

for pane in "${pane_coordinator:-}" "${pane_refactor_planner:-}" "${pane_plan_reviewer:-}" "${pane_backend_developer:-}" "${pane_fe_developer:-}" "${pane_qa_reviewer:-}"; do
  if [ -n "$pane" ] && [ "$pane" != "${leader_pane:-}" ] && tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    tmux kill-pane -t "$pane" || true
    echo "Stopped pane: $pane"
  fi
done

rm -f "$PANES_FILE"
echo "Stopped wms-refactor-lab panes."
