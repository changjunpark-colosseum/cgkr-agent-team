#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WMS="/Users/changjun/Desktop/cgkr_oncall"
MAX_TURNS="${MAX_TURNS:-8}"
TURN_TIMEOUT_SECONDS="${TURN_TIMEOUT_SECONDS:-1800}"
ROUTE="${ROUTE:-refactor-planner,plan-reviewer,refactor-planner,fe-developer,qa-reviewer,fe-developer,qa-reviewer}"
HANDOFF_ROUTING="${HANDOFF_ROUTING:-1}"
START_AGENT="${START_AGENT:-}"

usage() {
  cat <<USAGE
Usage: auto-loop.sh [task prompt]

Runs an automatic multi-turn WMS refactor conversation through registered tmux panes.

Environment:
  CODEX_BIN              Codex CLI binary (default: codex)
  CODEX_ARGS             extra args passed to codex exec
  WMS_WORKSPACE          target repo path
  MAX_TURNS              maximum turns (default: 8)
  TURN_TIMEOUT_SECONDS   per-turn timeout (default: 1800)
  ROUTE                  comma-separated agent route
                         used as fallback when no handoff is emitted
                         default: $ROUTE
  HANDOFF_ROUTING        route by <handoff>{"target":"..."}</handoff> when 1 (default: 1)
  START_AGENT            first agent when set; otherwise first ROUTE entry
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required." >&2
  exit 1
fi

CODEX_PATH="$(command -v "$CODEX_BIN" || true)"
if [ -z "$CODEX_PATH" ]; then
  echo "Codex CLI not found: $CODEX_BIN" >&2
  exit 1
fi

if [ -n "${WMS_WORKSPACE:-}" ]; then
  TARGET_WORKSPACE="$WMS_WORKSPACE"
elif [ -d "$DEFAULT_WMS" ]; then
  TARGET_WORKSPACE="$DEFAULT_WMS"
else
  TARGET_WORKSPACE="$PWD"
fi

PANES_FILE="$TARGET_WORKSPACE/.omx/wms-refactor-lab/panes.env"
if [ ! -f "$PANES_FILE" ]; then
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    "$SCRIPT_DIR/start.sh" "$TARGET_WORKSPACE"
  else
    cat >&2 <<'ERR'
No wms-refactor-lab panes are registered, and this process is not inside tmux.

Start Codex through OMX first:
  omx --tmux

Then run:
  $wms-refactor-lab
ERR
    exit 1
  fi
fi

# shellcheck disable=SC1090
. "$PANES_FILE"

STATE_DIR="$TARGET_WORKSPACE/.omx/wms-refactor-lab"
PROMPT_DIR="$STATE_DIR/prompts"
RUN_DIR="$STATE_DIR/run"
TRANSCRIPT="$STATE_DIR/transcript.md"
mkdir -p "$RUN_DIR"

if [ "$#" -gt 0 ]; then
  TASK="$*"
else
  TASK="$(cat)"
fi

if [ -z "$(printf '%s' "$TASK" | tr -d '[:space:]')" ]; then
  echo "Task prompt is required." >&2
  usage >&2
  exit 2
fi

if ! [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || [ "$MAX_TURNS" -lt 1 ]; then
  echo "MAX_TURNS must be a positive integer." >&2
  exit 2
fi

if ! [[ "$TURN_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$TURN_TIMEOUT_SECONDS" -lt 1 ]; then
  echo "TURN_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi

pane_for_agent() {
  case "$1" in
    coordinator) printf '%s\n' "${pane_coordinator:-}" ;;
    refactor-planner) printf '%s\n' "${pane_refactor_planner:-}" ;;
    plan-reviewer) printf '%s\n' "${pane_plan_reviewer:-}" ;;
    backend-developer) printf '%s\n' "${pane_backend_developer:-}" ;;
    fe-developer) printf '%s\n' "${pane_fe_developer:-}" ;;
    qa-reviewer) printf '%s\n' "${pane_qa_reviewer:-}" ;;
    *)
      echo "Unknown route agent: $1" >&2
      return 1
      ;;
  esac
}

normalize_agent() {
  local agent="$1"
  agent="${agent#@}"
  agent="${agent//_/-}"
  printf '%s\n' "$agent" | xargs
}

is_allowed_agent() {
  case "$(normalize_agent "$1")" in
    coordinator|refactor-planner|plan-reviewer|backend-developer|fe-developer|qa-reviewer) return 0 ;;
    *) return 1 ;;
  esac
}

route_agent_for_turn() {
  local turn_number="$1"
  local route_index=$(( (turn_number - 1) % ${#ROUTE_AGENTS[@]} ))
  normalize_agent "${ROUTE_AGENTS[$route_index]}"
}

extract_handoff_target() {
  local output_file="$1"
  perl -0ne '
    while (m|<handoff>\s*(\{.*?\})\s*</handoff>|sg) {
      my $json = $1;
      if ($json =~ /"target"\s*:\s*"@?([^"]+)"/) {
        print $1;
        exit;
      }
    }
  ' "$output_file" | head -n 1
}

role_prompt_for_agent() {
  local path="$PROMPT_DIR/$1.md"
  if [ ! -f "$path" ]; then
    echo "Missing role prompt: $path" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

wait_for_file() {
  local file="$1"
  local started
  started="$(date +%s)"
  while true; do
    if [ -f "$file" ]; then
      return 0
    fi
    local now
    now="$(date +%s)"
    if [ "$((now - started))" -ge "$TURN_TIMEOUT_SECONDS" ]; then
      return 1
    fi
    sleep 1
  done
}

IFS=',' read -r -a ROUTE_AGENTS <<< "$ROUTE"
if [ "${#ROUTE_AGENTS[@]}" -eq 0 ]; then
  echo "ROUTE must contain at least one agent." >&2
  exit 2
fi

if [ "$HANDOFF_ROUTING" != "0" ] && [ "$HANDOFF_ROUTING" != "1" ]; then
  echo "HANDOFF_ROUTING must be 0 or 1." >&2
  exit 2
fi

if [ -n "$START_AGENT" ]; then
  next_agent="$(normalize_agent "$START_AGENT")"
else
  next_agent="$(route_agent_for_turn 1)"
fi

if ! is_allowed_agent "$next_agent"; then
  echo "START_AGENT is not allowed: $next_agent" >&2
  exit 2
fi

cat > "$TRANSCRIPT" <<TRANSCRIPT
# WMS Refactor Lab Transcript

## User Task

$TASK

TRANSCRIPT

echo "Starting automatic WMS refactor loop"
echo "workspace: $TARGET_WORKSPACE"
echo "fallback route: $ROUTE"
echo "handoff routing: $HANDOFF_ROUTING"
echo "start agent: @$next_agent"
echo "max turns: $MAX_TURNS"

turn=1
while [ "$turn" -le "$MAX_TURNS" ]; do
  agent="$next_agent"
  pane="$(pane_for_agent "$agent")"
  role_prompt="$(role_prompt_for_agent "$agent")"

  if [ -z "$pane" ] || ! tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    echo "Pane for @$agent is missing or dead: $pane" >&2
    exit 1
  fi

  input_file="$RUN_DIR/turn-$turn-$agent.prompt.md"
  output_file="$RUN_DIR/turn-$turn-$agent.output.md"
  done_file="$RUN_DIR/turn-$turn-$agent.done"
  runner_file="$RUN_DIR/turn-$turn-$agent.sh"
  rm -f "$output_file" "$done_file"

  cat > "$input_file" <<PROMPT
$(cat "$role_prompt")

# Automatic Multi-Agent Turn

You are @$agent.

Original user task:
$TASK

Prior transcript:
$(cat "$TRANSCRIPT")

Instructions for this turn:
- Continue the workflow from the prior transcript.
- Stay in your assigned role.
- If this is planning or review, do not edit files.
- If this is implementation, make only scoped changes and report verification.
- If this is QA, review current diff/test evidence and end with one of:
  <workflow>{"status":"approved","message":"..."}</workflow>
  <workflow>{"status":"request_changes","message":"..."}</workflow>
  <workflow>{"status":"needs_planning","message":"..."}</workflow>
- To route the next turn, emit exactly one structured handoff:
  <handoff>{"target":"fe-developer","reason":"...","message":"..."}</handoff>
- Allowed handoff targets: coordinator, refactor-planner, plan-reviewer, backend-developer, fe-developer, qa-reviewer.
- Use backend-developer when frontend implementation needs cgkr_app controller/DTO/entity/API response clarification.
- Use structured handoff for routing. Casual @mentions in prose do not route the next turn.
- If you are QA and request changes, include a handoff to the agent that should act next.
- If you are done and no specialist needs the next turn, omit handoff and the broker will use the fallback route.
- Keep the response concise and handoff-ready.
PROMPT

  q_codex_path="$(shell_quote "$CODEX_PATH")"
  q_workspace="$(shell_quote "$TARGET_WORKSPACE")"
  q_input="$(shell_quote "$input_file")"
  q_output="$(shell_quote "$output_file")"
  q_done="$(shell_quote "$done_file")"
  q_agent="$(shell_quote "$agent")"
  codex_args_value="${CODEX_ARGS:-}"
  q_codex_args_value="$(shell_quote "$codex_args_value")"

  cat > "$runner_file" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
export LANG="\${LANG:-ko_KR.UTF-8}"
export LC_ALL="\${LC_ALL:-ko_KR.UTF-8}"
echo
echo "===== @$agent turn $turn ====="
CODEX_ARGS_VALUE=$q_codex_args_value
status=0
if [ -n "\$CODEX_ARGS_VALUE" ]; then
  # shellcheck disable=SC2086
  $q_codex_path exec -C $q_workspace --skip-git-repo-check --sandbox workspace-write --ask-for-approval never \$CODEX_ARGS_VALUE - < $q_input | tee $q_output
  status=\${PIPESTATUS[0]}
else
  $q_codex_path exec -C $q_workspace --skip-git-repo-check --sandbox workspace-write --ask-for-approval never - < $q_input | tee $q_output
  status=\${PIPESTATUS[0]}
fi
echo
echo "===== @$agent turn $turn done status=\$status ====="
printf '%s\n' "\$status" > $q_done
exec "\${SHELL:-/bin/zsh}" -l
RUNNER
  chmod +x "$runner_file"

  echo "turn $turn -> @$agent ($pane)"
  tmux respawn-pane -k -t "$pane" -c "$TARGET_WORKSPACE" "$runner_file"

  if ! wait_for_file "$done_file"; then
    echo "Turn $turn timed out for @$agent after ${TURN_TIMEOUT_SECONDS}s" >&2
    exit 1
  fi

  status="$(cat "$done_file" 2>/dev/null || echo 1)"
  {
    echo
    echo "## Turn $turn - @$agent"
    echo
    cat "$output_file"
    echo
  } >> "$TRANSCRIPT"

  if [ "$status" != "0" ]; then
    echo "Turn $turn failed for @$agent with status $status" >&2
    exit "$status"
  fi

  if [ "$agent" = "qa-reviewer" ] && grep -q '<workflow>{"status":"approved"' "$output_file"; then
    echo "QA approved at turn $turn."
    echo "Transcript: $TRANSCRIPT"
    exit 0
  fi

  next_turn=$((turn + 1))
  fallback_agent="$(route_agent_for_turn "$next_turn")"
  handoff_target=""
  if [ "$HANDOFF_ROUTING" = "1" ]; then
    handoff_target="$(extract_handoff_target "$output_file" || true)"
    handoff_target="$(normalize_agent "$handoff_target")"
  fi

  if [ -n "$handoff_target" ]; then
    if is_allowed_agent "$handoff_target"; then
      next_agent="$handoff_target"
      echo "handoff: @$agent -> @$next_agent"
    else
      next_agent="$fallback_agent"
      echo "Ignored invalid handoff target from @$agent: $handoff_target" >&2
      echo "fallback next: @$next_agent"
    fi
  else
    next_agent="$fallback_agent"
    echo "fallback next: @$next_agent"
  fi

  turn=$((turn + 1))
done

echo "Reached MAX_TURNS=$MAX_TURNS without QA approval."
echo "Transcript: $TRANSCRIPT"
exit 0
