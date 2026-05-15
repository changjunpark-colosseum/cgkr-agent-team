#!/usr/bin/env bash
set -euo pipefail

SESSION="${SESSION:-wms-refactor-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WMS="/Users/changjun/Desktop/cgkr_oncall"

if [ "$#" -lt 1 ]; then
  echo "Usage: send.sh @agent [message]" >&2
  echo "Agents: @coordinator @refactor-planner @plan-reviewer @backend-developer @fe-developer @qa-reviewer" >&2
  exit 2
fi

AGENT="${1#@}"
AGENT="${AGENT//-/_}"
shift

if [ -n "${WMS_WORKSPACE:-}" ]; then
  TARGET_WORKSPACE="$WMS_WORKSPACE"
elif [ -d "$DEFAULT_WMS" ]; then
  TARGET_WORKSPACE="$DEFAULT_WMS"
else
  TARGET_WORKSPACE="$PWD"
fi

PANES_FILE="$TARGET_WORKSPACE/.omx/wms-refactor-lab/panes.env"
if [ ! -f "$PANES_FILE" ]; then
  echo "Pane registry not found: $PANES_FILE" >&2
  echo "Start the lab first: $SCRIPT_DIR/start.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$PANES_FILE"

case "$AGENT" in
  coordinator) PANE="${pane_coordinator:-}" ;;
  refactor_planner) PANE="${pane_refactor_planner:-}" ;;
  plan_reviewer) PANE="${pane_plan_reviewer:-}" ;;
  backend_developer) PANE="${pane_backend_developer:-}" ;;
  fe_developer) PANE="${pane_fe_developer:-}" ;;
  qa_reviewer) PANE="${pane_qa_reviewer:-}" ;;
  *)
    echo "Unknown agent: @$AGENT" >&2
    exit 2
    ;;
esac

if [ -z "${PANE:-}" ]; then
  echo "No pane registered for @$AGENT" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

if [ "$#" -gt 0 ]; then
  printf '%s\n' "$*" > "$TMP_FILE"
else
  cat > "$TMP_FILE"
fi

tmux load-buffer -b wms-refactor-lab-message "$TMP_FILE"
tmux paste-buffer -b wms-refactor-lab-message -t "$PANE"
tmux send-keys -t "$PANE" C-m
echo "Sent message to @$AGENT ($PANE)"
