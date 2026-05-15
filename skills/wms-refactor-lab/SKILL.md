---
name: wms-refactor-lab
description: Split the current tmux-backed Codex/OMX window into independent Codex agent panes for WMS refactoring. Use when the user invokes $wms-refactor-lab, wants agent panes created inside the current terminal, asks for planner-reviewer-FE-QA refactor collaboration, or wants to coordinate WMS refactoring without the broker web UI/TUI.
---

# WMS Refactor Lab

## Quick Start

Launch independent Codex agent panes from inside an existing tmux-backed Codex/OMX session:

```bash
scripts/start.sh
```

If the user names a target repo, pass it as the first argument or set `WMS_WORKSPACE`:

```bash
scripts/start.sh /path/to/wms-repo
```

If `TMUX_PANE` is missing, restart Codex through OMX first:

```bash
omx --tmux
```

The current tmux window becomes:

- current pane: the user's leader Codex session
- split panes: independent Codex sessions for `@coordinator`, `@refactor-planner`, `@plan-reviewer`, `@backend-developer`, `@fe-developer`, and `@qa-reviewer`

This skill must not create a detached tmux session, launch the broker browser UI, or launch the broker TUI by default. The point is pane-per-agent Codex in the current terminal.

## Sending Messages

Prefer the automatic loop. It routes outputs between agent panes without manual copy/paste:

```bash
scripts/auto-loop.sh "WMS 로그인 페이지 리팩토링을 계획, 리뷰, 구현, QA 루프로 진행해."
```

Use the parallel loop when independent planning/review work should happen at the same time:

```bash
scripts/parallel-loop.sh "WMS 로그인 페이지 리팩토링을 계획, 리뷰, 구현, QA 루프로 진행해."
```

The parallel loop uses barrier rounds:

```text
Round 1: refactor-planner + backend-developer + qa-reviewer run in parallel
Round 2: coordinator merges those outputs into one FE implementation brief
Cycle N: fe-developer implements
Cycle N review: qa-reviewer + plan-reviewer + backend-developer review in parallel
Cycle N decision: coordinator approves, requests FE changes, or asks for planning revision
```

By default the automatic loop uses structured handoffs when an agent emits one:

```text
<handoff>{"target":"fe-developer","reason":"QA requested changes","message":"Fix the stale selection regression and rerun focused tests."}</handoff>
```

Use `@backend-developer` when frontend work needs cgkr_app domain/API clarification:

```text
<handoff>{"target":"backend-developer","reason":"Backend contract clarification needed","message":"Inspect cgkr_app CartController/DTO and explain the required response body fields for cart list and container-list."}</handoff>
```

If no valid handoff is emitted, the loop falls back to `ROUTE`.

Use environment variables to tune the loop:

```bash
MAX_TURNS=12 ROUTE="refactor-planner,plan-reviewer,refactor-planner,fe-developer,qa-reviewer,fe-developer,qa-reviewer" \
  scripts/auto-loop.sh "리팩토링 목표..."
```

Disable dynamic handoff routing when you want the fixed route only:

```bash
HANDOFF_ROUTING=0 MAX_TURNS=12 \
  scripts/auto-loop.sh "리팩토링 목표..."
```

Manual send remains available for intervention or one-off messages:

```bash
scripts/send.sh @refactor-planner "Plan a safe refactor for src/pages/sign-in."
```

Pipe longer prompts through stdin:

```bash
cat prompt.md | scripts/send.sh @fe-developer
```

Use tmux directly when more convenient:

```bash
tmux select-pane -t <pane-id>
```

## Feature Boundary Gate

Before planning or implementing any WMS FSD migration/refactor, the lab must first decide whether the proposed feature root is a real user capability/use case.

This gate is mandatory for all page-to-feature migrations and broad refactors. Do not proceed to implementation until the agents have written a pass/conditional/nonpass boundary decision.

A feature root should be named after a cohesive capability, for example:

- `cart-list`
- `create-cart`
- `delete-cart`
- `print-cart-labels`
- `print-container-labels`

Suspicious bucket names require explicit justification and are nonpass by default:

- `*-management`
- `*-manager`
- `*-container`
- `*-module`
- `*-page`
- `common`
- `utils`

Feature boundary nonpass conditions:

- list/create/delete/print/download are grouped only because they appear on one page
- the folder name describes a screen bucket rather than a user action or use case
- multiple independent reasons to change exist under one feature root
- command/query concerns are mixed without a documented transition plan
- a page composition shell owns all API/schema/hooks as if it were the final feature

Allowed temporary exception:

- A broad page-composition shell may exist only as a transitional widget/page orchestration layer.
- The shell must not be treated as the final feature boundary.
- The plan must name the target use-case features and explain what moves now, what stays temporarily, and what test locks protect the transition.

## Recommended Flow

The automatic loop handles the normal review loop:

0. `@refactor-planner`, `@plan-reviewer`, `@backend-developer`, `@fe-developer`, and `@qa-reviewer` apply the Feature Boundary Gate when the task creates or renames a feature root.
1. `@refactor-planner` creates a scoped plan only after the boundary decision is explicit.
2. `@plan-reviewer` reviews the plan and treats unresolved feature-boundary naming/cohesion issues as blocking.
3. `@refactor-planner` revises if needed.
4. `@backend-developer` clarifies cgkr_app controller/DTO/domain contracts when requested.
5. `@fe-developer` implements.
6. `@qa-reviewer` reviews.
7. If QA requests changes, the route cycles back through FE and QA.

The relay writes a transcript at `.omx/wms-refactor-lab/transcript.md` and injects that transcript into the next turn so agents stay aligned without manual paste. Agents can route dynamically with `<handoff>{"target":"..."}</handoff>`; otherwise the configured `ROUTE` is used as a fallback.

## Configuration

Environment variables:

- `CODEX_BIN`: Codex CLI binary. Default: `codex`
- `CODEX_ARGS`: extra args passed to every Codex agent
- `WMS_WORKSPACE`: target repo path. Default: `/Users/changjun/Desktop/cgkr_oncall` if it exists, otherwise current directory
- `AGENTS_DIR`: role prompt directory. Default: `<skill>/agents`
- `MAX_TURNS`: max automatic turns for `auto-loop.sh`. Default: `8`
- `MAX_CYCLES`: max FE/review cycles for `parallel-loop.sh`. Default: `3`
- `ROUTE`: comma-separated fallback route for `auto-loop.sh`
- `PLANNING_AGENTS`: comma-separated planning round agents for `parallel-loop.sh`
- `REVIEW_AGENTS`: comma-separated parallel review agents for `parallel-loop.sh`
- `HANDOFF_ROUTING`: set to `1` to let structured handoffs choose the next agent. Default: `1`
- `START_AGENT`: optional first agent. Default: first `ROUTE` entry
- `TURN_TIMEOUT_SECONDS`: per-turn timeout for `auto-loop.sh`. Default: `1800`

Utility commands:

```bash
scripts/status.sh
scripts/stop.sh
scripts/start.sh --restart
scripts/auto-loop.sh "task"
scripts/parallel-loop.sh "task"
```
