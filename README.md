# WMS Refactor Lab

Codex plugin for running a tmux-backed multi-agent WMS refactor workflow.

The plugin provides one skill:

```text
wms-refactor-lab
```

It creates independent Codex panes for:

- `@coordinator`
- `@refactor-planner`
- `@plan-reviewer`
- `@backend-developer`
- `@fe-developer`
- `@qa-reviewer`

## Layout

```text
.codex-plugin/plugin.json
docs/
skills/wms-refactor-lab/
  SKILL.md
  agents/
  scripts/
```

## Docs

- [Team Command Router](docs/team-command-router.md): proposed OMX-like command surface for reusable team presets such as `team:qa`, `team:refactor`, and `team:domain`.

## Usage

Start Codex through a tmux-capable session, then invoke the skill:

```text
$wms-refactor-lab
```

Or run the scripts directly from the skill directory:

```bash
cd skills/wms-refactor-lab
scripts/start.sh /Users/changjun/Desktop/cgkr_oncall
scripts/parallel-loop.sh "CartList 리팩토링을 계획, 구현, QA 루프로 진행해"
```

## Workflow Modes

Serial loop:

```bash
skills/wms-refactor-lab/scripts/auto-loop.sh "작업 내용"
```

Parallel barrier loop:

```bash
skills/wms-refactor-lab/scripts/parallel-loop.sh "작업 내용"
```

The parallel loop runs:

```text
planning agents in parallel
coordinator synthesis
FE implementation
review agents in parallel
coordinator decision
```

## Configuration

Common environment variables:

```text
WMS_WORKSPACE=/path/to/cgkr_oncall
CODEX_BIN=codex
CODEX_ARGS=
MAX_TURNS=8
MAX_CYCLES=3
TURN_TIMEOUT_SECONDS=1800
```

## Project-Specific Assumptions

The default workspace is:

```text
/Users/changjun/Desktop/cgkr_oncall
```

The backend contract reviewer expects:

```text
/Users/changjun/Desktop/cgkr_app
```

Override `WMS_WORKSPACE` or pass a workspace path to `scripts/start.sh` when using a different checkout.
