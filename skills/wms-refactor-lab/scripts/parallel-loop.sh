#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WMS="/Users/changjun/Desktop/cgkr_oncall"
TURN_TIMEOUT_SECONDS="${TURN_TIMEOUT_SECONDS:-1800}"
MAX_CYCLES="${MAX_CYCLES:-3}"
PLANNING_AGENTS="${PLANNING_AGENTS:-refactor-planner,backend-developer,qa-reviewer}"
REVIEW_AGENTS="${REVIEW_AGENTS:-qa-reviewer,plan-reviewer,backend-developer}"

usage() {
  cat <<USAGE
Usage: parallel-loop.sh [task prompt]

Runs a barrier-based parallel WMS refactor workflow:
  1. planning agents run in parallel
  2. coordinator synthesizes
  3. fe-developer implements
  4. review agents run in parallel
  5. coordinator approves or requests another FE/review cycle

Environment:
  CODEX_BIN              Codex CLI binary (default: codex)
  CODEX_ARGS             extra args passed to codex exec
  WMS_WORKSPACE          target repo path
  TURN_TIMEOUT_SECONDS   per-agent timeout (default: 1800)
  MAX_CYCLES             max FE/review cycles (default: 3)
  PLANNING_AGENTS        comma-separated planning round agents
                         default: $PLANNING_AGENTS
  REVIEW_AGENTS          comma-separated parallel review agents
                         default: $REVIEW_AGENTS
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

if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
  echo "MAX_CYCLES must be a positive integer." >&2
  exit 2
fi

if ! [[ "$TURN_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$TURN_TIMEOUT_SECONDS" -lt 1 ]; then
  echo "TURN_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi

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

pane_for_agent() {
  case "$(normalize_agent "$1")" in
    coordinator) printf '%s\n' "${pane_coordinator:-}" ;;
    refactor-planner) printf '%s\n' "${pane_refactor_planner:-}" ;;
    plan-reviewer) printf '%s\n' "${pane_plan_reviewer:-}" ;;
    backend-developer) printf '%s\n' "${pane_backend_developer:-}" ;;
    fe-developer) printf '%s\n' "${pane_fe_developer:-}" ;;
    qa-reviewer) printf '%s\n' "${pane_qa_reviewer:-}" ;;
    *)
      echo "Unknown agent: $1" >&2
      return 1
      ;;
  esac
}

role_prompt_for_agent() {
  local agent
  agent="$(normalize_agent "$1")"
  local path="$PROMPT_DIR/$agent.md"
  if [ ! -f "$path" ]; then
    echo "Missing role prompt: $path" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

normalize_agent_csv() {
  local csv="$1"
  local item normalized
  IFS=',' read -r -a raw_agents <<< "$csv"
  for item in "${raw_agents[@]}"; do
    normalized="$(normalize_agent "$item")"
    [ -n "$normalized" ] || continue
    if ! is_allowed_agent "$normalized"; then
      echo "Agent is not allowed: $normalized" >&2
      exit 2
    fi
    printf '%s\n' "$normalized"
  done
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

run_agent_async() {
  local label="$1"
  local agent="$2"
  local instructions="$3"
  local pane role_prompt input_file output_file done_file runner_file
  agent="$(normalize_agent "$agent")"
  pane="$(pane_for_agent "$agent")"
  role_prompt="$(role_prompt_for_agent "$agent")"

  if [ -z "$pane" ] || ! tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    echo "Pane for @$agent is missing or dead: $pane" >&2
    exit 1
  fi

  input_file="$RUN_DIR/$label-$agent.prompt.md"
  output_file="$RUN_DIR/$label-$agent.output.md"
  done_file="$RUN_DIR/$label-$agent.done"
  runner_file="$RUN_DIR/$label-$agent.sh"
  rm -f "$output_file" "$done_file"

  cat > "$input_file" <<PROMPT
$(cat "$role_prompt")

# Parallel WMS Refactor Lab Turn

You are @$agent.

Original user task:
$TASK

Current shared transcript:
$(cat "$TRANSCRIPT")

Instructions for this turn:
$instructions

General constraints:
- Stay in your assigned role.
- Do not assume other panes can see your private context.
- If this is planning or review, do not edit files.
- Only fe-developer may implement frontend code in this parallel loop.
- Keep the response concise and merge-ready for coordinator.
PROMPT

  q_codex_path="$(shell_quote "$CODEX_PATH")"
  q_workspace="$(shell_quote "$TARGET_WORKSPACE")"
  q_input="$(shell_quote "$input_file")"
  q_output="$(shell_quote "$output_file")"
  q_done="$(shell_quote "$done_file")"
  codex_args_value="${CODEX_ARGS:-}"
  q_codex_args_value="$(shell_quote "$codex_args_value")"

  cat > "$runner_file" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
export LANG="\${LANG:-ko_KR.UTF-8}"
export LC_ALL="\${LC_ALL:-ko_KR.UTF-8}"
echo
echo "===== @$agent $label ====="
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
echo "===== @$agent $label done status=\$status ====="
printf '%s\n' "\$status" > $q_done
exec "\${SHELL:-/bin/zsh}" -l
RUNNER
  chmod +x "$runner_file"

  echo "$label -> @$agent ($pane)"
  tmux respawn-pane -k -t "$pane" -c "$TARGET_WORKSPACE" "$runner_file"
}

append_output() {
  local heading="$1"
  local label="$2"
  shift 2
  local agent output_file
  {
    echo
    echo "## $heading"
    echo
  } >> "$TRANSCRIPT"

  for agent in "$@"; do
    output_file="$RUN_DIR/$label-$agent.output.md"
    {
      echo
      echo "### @$agent"
      echo
      cat "$output_file"
      echo
    } >> "$TRANSCRIPT"
  done
}

wait_for_agents() {
  local label="$1"
  shift
  local agent done_file status
  for agent in "$@"; do
    done_file="$RUN_DIR/$label-$agent.done"
    if ! wait_for_file "$done_file"; then
      echo "$label timed out for @$agent after ${TURN_TIMEOUT_SECONDS}s" >&2
      exit 1
    fi
  done
  for agent in "$@"; do
    done_file="$RUN_DIR/$label-$agent.done"
    status="$(cat "$done_file" 2>/dev/null || echo 1)"
    if [ "$status" != "0" ]; then
      echo "$label failed for @$agent with status $status" >&2
      exit "$status"
    fi
  done
}

run_parallel_round() {
  local label="$1"
  local heading="$2"
  local instructions="$3"
  shift 3
  local agents=("$@")
  local agent
  for agent in "${agents[@]}"; do
    run_agent_async "$label" "$agent" "$instructions"
  done
  wait_for_agents "$label" "${agents[@]}"
  append_output "$heading" "$label" "${agents[@]}"
}

run_single_agent() {
  local label="$1"
  local heading="$2"
  local agent="$3"
  local instructions="$4"
  run_agent_async "$label" "$agent" "$instructions"
  wait_for_agents "$label" "$agent"
  append_output "$heading" "$label" "$agent"
}

planning_agents=()
while IFS= read -r agent; do
  planning_agents+=("$agent")
done < <(normalize_agent_csv "$PLANNING_AGENTS")

review_agents=()
while IFS= read -r agent; do
  review_agents+=("$agent")
done < <(normalize_agent_csv "$REVIEW_AGENTS")

if [ "${#planning_agents[@]}" -eq 0 ]; then
  echo "PLANNING_AGENTS must not be empty." >&2
  exit 2
fi

if [ "${#review_agents[@]}" -eq 0 ]; then
  echo "REVIEW_AGENTS must not be empty." >&2
  exit 2
fi

cat > "$TRANSCRIPT" <<TRANSCRIPT
# WMS Refactor Lab Parallel Transcript

## User Task

$TASK

TRANSCRIPT

echo "Starting parallel WMS refactor loop"
echo "workspace: $TARGET_WORKSPACE"
echo "planning agents: ${planning_agents[*]}"
echo "review agents: ${review_agents[*]}"
echo "max FE/review cycles: $MAX_CYCLES"

run_parallel_round "round-1-planning" "Round 1 - Parallel Planning" \
"- Produce role-specific planning input for coordinator.
- refactor-planner: create bounded refactor plan, behavior locks, implementation constraints.
- backend-developer: inspect cgkr_app only when useful; clarify API/domain/DTO risks and contract assumptions. Do not edit files.
- qa-reviewer: define QA gates, regression risks, and verification evidence. Do not require implementation review yet.
- Do not emit final approval. This is an input round for coordinator." \
"${planning_agents[@]}"

run_single_agent "round-2-coordinate-plan" "Round 2 - Coordinator Plan Synthesis" "coordinator" \
"Synthesize the parallel planning outputs into one actionable implementation brief for FE.
Include consolidated scope, backend/API assumptions or blockers, behavior locks, QA/test gates, and exact FE instructions.
If implementation is unsafe because planning/backend contract is insufficient, end with:
<workflow>{\"status\":\"needs_planning\",\"message\":\"...\"}</workflow>
Otherwise do not approve yet; provide a clear implementation brief."

if grep -q '<workflow>{"status":"needs_planning"' "$RUN_DIR/round-2-coordinate-plan-coordinator.output.md"; then
  echo "Coordinator requested planning revision before implementation."
  echo "Transcript: $TRANSCRIPT"
  exit 0
fi

cycle=1
while [ "$cycle" -le "$MAX_CYCLES" ]; do
  run_single_agent "cycle-$cycle-implementation" "Cycle $cycle - FE Implementation" "fe-developer" \
"Implement only the coordinator-approved scope.
Read the WMS refactor guide and related docs named in your role prompt before editing.
If backend contract is unclear, stop and emit a handoff to backend-developer instead of guessing.
Report changed files, docs/contracts consulted, implementation summary, verification, and risks."

  run_parallel_round "cycle-$cycle-review" "Cycle $cycle - Parallel Review" \
"Review the current implementation and transcript from your role.
- qa-reviewer: inspect diff/test evidence and emit one workflow decision block.
- plan-reviewer: review plan adherence, scope creep, architecture/test gaps. Do not edit files.
- backend-developer: review API contract/DTO/domain assumptions against cgkr_app when relevant. Do not edit files.
- Keep findings concrete and merge-ready for coordinator." \
"${review_agents[@]}"

  run_single_agent "cycle-$cycle-coordinate-review" "Cycle $cycle - Coordinator Review Synthesis" "coordinator" \
"Synthesize the parallel review outputs into one final workflow decision.
If all blocking concerns are resolved, end with:
<workflow>{\"status\":\"approved\",\"message\":\"...\"}</workflow>
If FE must fix implementation, end with:
<workflow>{\"status\":\"request_changes\",\"message\":\"specific FE fixes...\"}</workflow>
If the plan/scope must change before FE continues, end with:
<workflow>{\"status\":\"needs_planning\",\"message\":\"specific planning revision...\"}</workflow>
Do not leave the decision implicit."

  coordinator_output="$RUN_DIR/cycle-$cycle-coordinate-review-coordinator.output.md"
  if grep -q '<workflow>{"status":"approved"' "$coordinator_output"; then
    echo "Coordinator approved at cycle $cycle."
    echo "Transcript: $TRANSCRIPT"
    exit 0
  fi

  if grep -q '<workflow>{"status":"needs_planning"' "$coordinator_output"; then
    echo "Coordinator requested planning revision at cycle $cycle."
    echo "Transcript: $TRANSCRIPT"
    exit 0
  fi

  if grep -q '<workflow>{"status":"request_changes"' "$coordinator_output"; then
    echo "Coordinator requested FE changes at cycle $cycle; continuing."
    cycle=$((cycle + 1))
    continue
  fi

  echo "Coordinator did not emit a valid workflow decision at cycle $cycle." >&2
  echo "Transcript: $TRANSCRIPT"
  exit 1
done

echo "Reached MAX_CYCLES=$MAX_CYCLES without coordinator approval."
echo "Transcript: $TRANSCRIPT"
exit 0
