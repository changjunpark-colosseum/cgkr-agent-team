# Team Command Router

This document describes the next expansion direction for `cgkr-agent-team`: an OMX-like command surface for reusable team workflows.

## Goal

The current plugin runs one WMS refactor lab skill. The next useful step is to keep a single plugin entry point while allowing command-like team presets such as:

```text
$cgkr-agent-team team:qa "CartList migration QA report"
$cgkr-agent-team team:refactor "Refactor the login page through plan, implementation, and QA"
$cgkr-agent-team team:domain "Interview the WMS outbound domain"
```

The important design choice is that `team:qa` should not be a separate global binary or separate Codex primitive. It should be a routed command handled by the plugin skill.

## Recommended Structure

```text
cgkr-agent-team/
  .codex-plugin/plugin.json
  skills/
    cgkr-agent-team/
      SKILL.md
      commands/
        team.qa.md
        team.refactor.md
        team.domain.md
      teams/
        qa.yaml
        refactor.yaml
        domain.yaml
      agents/
        qa-lead.md
        qa-functional.md
        qa-regression.md
        qa-automation.md
        planner.md
        backend-developer.md
        fe-developer.md
      scripts/
        dispatch.sh
        start.sh
        parallel-loop.sh
        auto-loop.sh
```

## Command Routing Model

The user-facing command stays compact:

```text
$cgkr-agent-team team:qa "Run QA for CartList migration"
```

The dispatcher resolves it as:

```text
team:qa
  -> commands/team.qa.md
  -> teams/qa.yaml
  -> agents/qa-lead.md, qa-functional.md, qa-regression.md, qa-automation.md
  -> scripts/parallel-loop.sh or a QA-specific loop
```

This keeps the system close to OMX's skill model while preserving a project-specific SSOT.

## QA Team Example

```yaml
name: qa
lead: qa-lead
members:
  - qa-functional
  - qa-regression
  - qa-automation
parallel_round:
  - qa-functional
  - qa-regression
  - qa-automation
final_reviewer: qa-lead
outputs:
  - qa-report.md
  - failed-cases.md
  - developer-tickets.md
gates:
  - focused_tests
  - typecheck
  - build
  - manual_risk_notes
```

Expected workflow:

1. `qa-lead` defines QA scope and acceptance criteria.
2. `qa-functional`, `qa-regression`, and `qa-automation` review in parallel.
3. `qa-lead` merges the reports.
4. If failures are found, the lead creates structured handoffs to `@fe-developer` or `@backend-developer`.
5. The final output is a QA report plus developer-facing tickets.

## SSOT Rules

Keep the sources of truth separated:

| Concern | Source of truth |
| --- | --- |
| Command definitions | `skills/cgkr-agent-team/commands/` |
| Team composition | `skills/cgkr-agent-team/teams/` |
| Agent persona and responsibilities | `skills/cgkr-agent-team/agents/` |
| Runtime implementation | `skills/cgkr-agent-team/scripts/` |
| WMS domain/refactor rules | `cgkr_oncall/docs/` |
| Backend contract evidence | `cgkr_app` |
| Execution transcript | target repo `.omx/wms-refactor-lab/transcript.md` |

Do not duplicate WMS business rules into the plugin. The plugin should reference project docs and inject them into the right agents.

## Why Single Entry Point Is Better

Avoid creating many unrelated skills such as:

```text
$team-qa
$team-refactor
$team-domain
$team-planning
```

That makes discovery harder and spreads routing logic across too many surfaces.

Prefer:

```text
$cgkr-agent-team team:qa ...
$cgkr-agent-team team:refactor ...
$cgkr-agent-team team:domain ...
```

The single entry point can still feel like a command system, but it keeps ownership and versioning simple.

## Implementation Notes

`dispatch.sh` should:

1. Parse the first argument as a command key, for example `team:qa`.
2. Load the matching command prompt from `commands/`.
3. Load the matching team preset from `teams/`.
4. Start required tmux panes if they are missing.
5. Choose serial, parallel, or barrier loop based on the team preset.
6. Inject the task prompt, project transcript, and relevant docs into the first round.

The Codex skill should explain the same routing contract so users can invoke it naturally from Codex:

```text
$cgkr-agent-team team:qa "..."
```

## Guardrails

- Use team presets for repeatable work processes, not one-off trivial edits.
- Keep command files small and declarative.
- Keep role prompts role-specific; do not let every agent become a coordinator.
- Let `@coordinator` own merge/barrier decisions.
- Make QA outputs concrete: commands run, pass/fail evidence, failed cases, owner handoff, residual manual risk.
- Treat `team:domain` as an interview/research workflow, not an implementation workflow.

## Decision

The command router is feasible and is the right direction if the goal is to modularize real work processes such as QA teams, refactor teams, and WMS domain interviews.

The recommended next implementation step is to add a `cgkr-agent-team` dispatcher skill above the existing `wms-refactor-lab` skill, then migrate `wms-refactor-lab` into the first preset:

```text
team:refactor
```
