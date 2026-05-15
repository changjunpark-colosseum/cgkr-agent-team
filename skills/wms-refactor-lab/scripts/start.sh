#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="${AGENTS_DIR:-$SKILL_DIR/agents}"
STATUS_SCRIPT="$SCRIPT_DIR/status.sh"
SEND_SCRIPT="$SCRIPT_DIR/send.sh"
DEFAULT_WMS="/Users/changjun/Desktop/cgkr_oncall"
RESTART=0
WORKSPACE_ARG=""

usage() {
  cat <<USAGE
Usage: start.sh [--restart] [wms-workspace]

Splits the current tmux window and launches independent Codex panes:
  @coordinator
  @refactor-planner
  @plan-reviewer
  @backend-developer
  @fe-developer
  @qa-reviewer

This must run from inside an existing tmux-backed Codex/omx session.
Start Codex with: omx --tmux

Environment:
  CODEX_BIN      Codex CLI binary (default: codex)
  CODEX_ARGS     extra args passed to every Codex pane
  WMS_WORKSPACE  target WMS repo path
  AGENTS_DIR     role prompt dir (default: <skill>/agents)
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --restart)
      RESTART=1
      ;;
    --attach)
      echo "--attach is no longer used. Run this from inside tmux; panes are created in the current window." >&2
      exit 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -z "$WORKSPACE_ARG" ]; then
        WORKSPACE_ARG="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
  shift
done

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required." >&2
  exit 1
fi

if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
  cat >&2 <<'ERR'
wms-refactor-lab must run inside an existing tmux pane.

Restart Codex through OMX first:
  omx --tmux

Then invoke:
  $wms-refactor-lab
ERR
  exit 1
fi

CODEX_PATH="$(command -v "$CODEX_BIN" || true)"
if [ -z "$CODEX_PATH" ]; then
  echo "Codex CLI not found: $CODEX_BIN" >&2
  exit 1
fi

if [ ! -d "$AGENTS_DIR" ]; then
  echo "Agent prompt directory not found: $AGENTS_DIR" >&2
  exit 1
fi

if [ -n "${WMS_WORKSPACE:-}" ]; then
  TARGET_WORKSPACE="$WMS_WORKSPACE"
elif [ -n "$WORKSPACE_ARG" ]; then
  TARGET_WORKSPACE="$WORKSPACE_ARG"
elif [ -d "$DEFAULT_WMS" ]; then
  TARGET_WORKSPACE="$DEFAULT_WMS"
else
  TARGET_WORKSPACE="$PWD"
fi

if [ ! -d "$TARGET_WORKSPACE" ]; then
  echo "WMS workspace not found: $TARGET_WORKSPACE" >&2
  exit 1
fi

CONTEXT="$(tmux display-message -p -t "$TMUX_PANE" '#S:#I #{pane_id}')"
SESSION_WINDOW="${CONTEXT%% *}"
LEADER_PANE_ID="${CONTEXT##* }"
SESSION_NAME="${SESSION_WINDOW%%:*}"
WINDOW_INDEX="${SESSION_WINDOW##*:}"

if [ -z "$SESSION_NAME" ] || [ -z "$WINDOW_INDEX" ] || [[ "$LEADER_PANE_ID" != %* ]]; then
  echo "Failed to detect current tmux leader pane: $CONTEXT" >&2
  exit 1
fi

STATE_DIR="$TARGET_WORKSPACE/.omx/wms-refactor-lab"
PROMPT_DIR="$STATE_DIR/prompts"
RUN_DIR="$STATE_DIR/run"
PANES_FILE="$STATE_DIR/panes.env"
mkdir -p "$PROMPT_DIR" "$RUN_DIR"

pane_exists() {
  local pane="$1"
  [ -n "$pane" ] && tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1
}

kill_registered_panes() {
  [ -f "$PANES_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$PANES_FILE"
  local panes=(
    "${pane_coordinator:-}"
    "${pane_refactor_planner:-}"
    "${pane_plan_reviewer:-}"
    "${pane_backend_developer:-}"
    "${pane_fe_developer:-}"
    "${pane_qa_reviewer:-}"
  )
  local pane
  for pane in "${panes[@]}"; do
    if [ "$pane" != "$LEADER_PANE_ID" ] && pane_exists "$pane"; then
      tmux kill-pane -t "$pane" || true
    fi
  done
}

if [ -f "$PANES_FILE" ]; then
  # shellcheck disable=SC1090
  . "$PANES_FILE"
  existing_live=0
  for pane in "${pane_coordinator:-}" "${pane_refactor_planner:-}" "${pane_plan_reviewer:-}" "${pane_backend_developer:-}" "${pane_fe_developer:-}" "${pane_qa_reviewer:-}"; do
    if pane_exists "$pane"; then
      existing_live=1
      break
    fi
  done

  if [ "$existing_live" -eq 1 ]; then
    if [ "$RESTART" -eq 1 ]; then
      kill_registered_panes
    else
      echo "wms-refactor-lab panes already exist. Use --restart to replace them." >&2
      exit 1
    fi
  fi
fi

strip_frontmatter() {
  awk '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0; next }
    !in_fm { print }
  ' "$1"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

write_prompt() {
  local agent="$1"
  local role_file="$AGENTS_DIR/$agent.md"
  local prompt_file="$PROMPT_DIR/$agent.md"

  if [ ! -f "$role_file" ]; then
    echo "Missing role prompt: $role_file" >&2
    exit 1
  fi

  {
    echo "# @$agent"
    echo
    strip_frontmatter "$role_file"
    cat <<COMMON

You are running as an independent Codex CLI pane created beside the user's leader pane.

Workspace:
$TARGET_WORKSPACE

Tmux:
- Session/window: $SESSION_WINDOW
- Leader pane: $LEADER_PANE_ID

Collaboration rules:
- Stay in your assigned role.
- Do not assume other panes can see your context.
- When handing off, write a concise message addressed to the target agent.
- If you receive QA feedback, either implement the requested fix or clearly object with evidence.
- For implementation agents, inspect files before editing and run focused verification.
- Keep outputs concise enough to paste or send into another pane.

Useful local commands:
- Status: $STATUS_SCRIPT
- Send to another pane: $SEND_SCRIPT @agent "message"

Wait for the user's first task. Do not start modifying files until given a concrete scope.
COMMON
  } > "$prompt_file"
}

write_launcher() {
  local agent="$1"
  local prompt_file="$PROMPT_DIR/$agent.md"
  local launcher="$RUN_DIR/run-$agent.sh"
  local codex_args_value="${CODEX_ARGS:-}"
  local q_codex_args_value q_codex_path q_target_workspace q_prompt_file
  q_codex_args_value="$(shell_quote "$codex_args_value")"
  q_codex_path="$(shell_quote "$CODEX_PATH")"
  q_target_workspace="$(shell_quote "$TARGET_WORKSPACE")"
  q_prompt_file="$(shell_quote "$prompt_file")"

  cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
export LANG="\${LANG:-ko_KR.UTF-8}"
export LC_ALL="\${LC_ALL:-ko_KR.UTF-8}"
CODEX_ARGS_VALUE=$q_codex_args_value
if [ -n "\$CODEX_ARGS_VALUE" ]; then
  # shellcheck disable=SC2086
  exec $q_codex_path --no-alt-screen -C $q_target_workspace --sandbox workspace-write --ask-for-approval never \$CODEX_ARGS_VALUE "\$(cat $q_prompt_file)"
fi
exec $q_codex_path --no-alt-screen -C $q_target_workspace --sandbox workspace-write --ask-for-approval never "\$(cat $q_prompt_file)"
LAUNCHER
  chmod +x "$launcher"
  printf '%s\n' "$launcher"
}

split_agent() {
  local agent="$1"
  local direction="$2"
  local target="$3"
  local launcher
  launcher="$(write_launcher "$agent")"
  tmux split-window "$direction" -t "$target" -d -P -F '#{pane_id}' -c "$TARGET_WORKSPACE" "$launcher"
}

AGENTS=(coordinator refactor-planner plan-reviewer backend-developer fe-developer qa-reviewer)
for agent in "${AGENTS[@]}"; do
  write_prompt "$agent"
done

P_COORDINATOR="$(split_agent coordinator -h "$LEADER_PANE_ID")"
P_PLANNER="$(split_agent refactor-planner -v "$P_COORDINATOR")"
P_PLAN_REVIEWER="$(split_agent plan-reviewer -v "$P_COORDINATOR")"
P_BACKEND="$(split_agent backend-developer -v "$P_COORDINATOR")"
P_FE="$(split_agent fe-developer -v "$P_COORDINATOR")"
P_QA="$(split_agent qa-reviewer -v "$P_COORDINATOR")"

tmux select-pane -t "$P_COORDINATOR" -T "@coordinator"
tmux select-pane -t "$P_PLANNER" -T "@refactor-planner"
tmux select-pane -t "$P_PLAN_REVIEWER" -T "@plan-reviewer"
tmux select-pane -t "$P_BACKEND" -T "@backend-developer"
tmux select-pane -t "$P_FE" -T "@fe-developer"
tmux select-pane -t "$P_QA" -T "@qa-reviewer"

{
  printf 'SESSION_NAME=%q\n' "$SESSION_NAME"
  printf 'SESSION_WINDOW=%q\n' "$SESSION_WINDOW"
  printf 'WORKSPACE=%q\n' "$TARGET_WORKSPACE"
  printf 'leader_pane=%q\n' "$LEADER_PANE_ID"
  printf 'pane_coordinator=%q\n' "$P_COORDINATOR"
  printf 'pane_refactor_planner=%q\n' "$P_PLANNER"
  printf 'pane_plan_reviewer=%q\n' "$P_PLAN_REVIEWER"
  printf 'pane_backend_developer=%q\n' "$P_BACKEND"
  printf 'pane_fe_developer=%q\n' "$P_FE"
  printf 'pane_qa_reviewer=%q\n' "$P_QA"
} > "$PANES_FILE"

tmux select-layout -t "$SESSION_WINDOW" main-vertical >/dev/null || true
WINDOW_WIDTH="$(tmux display-message -p -t "$SESSION_WINDOW" '#{window_width}' 2>/dev/null || true)"
if [[ "$WINDOW_WIDTH" =~ ^[0-9]+$ ]] && [ "$WINDOW_WIDTH" -ge 80 ]; then
  tmux set-window-option -t "$SESSION_WINDOW" main-pane-width "$((WINDOW_WIDTH / 2))" >/dev/null || true
  tmux select-layout -t "$SESSION_WINDOW" main-vertical >/dev/null || true
fi
tmux set-option -t "$SESSION_NAME" mouse on >/dev/null || true
tmux select-pane -t "$LEADER_PANE_ID"

echo "Started WMS refactor lab in current tmux window: $SESSION_WINDOW"
echo "Leader pane: $LEADER_PANE_ID"
echo "Agent panes:"
echo "  @coordinator      $P_COORDINATOR"
echo "  @refactor-planner $P_PLANNER"
echo "  @plan-reviewer    $P_PLAN_REVIEWER"
echo "  @backend-developer $P_BACKEND"
echo "  @fe-developer     $P_FE"
echo "  @qa-reviewer      $P_QA"
echo "Send example: $SEND_SCRIPT @refactor-planner \"Plan the sign-in refactor.\""
