---
name: shepherd
description: Delegate bounded investigation, implementation, and review from Claude Code to Codex CLI workers. Use configurable model tiers, effort ceilings, sandbox modes, timeouts, and quota fallback while Claude remains lead and reviewer.
---

# shepherd

Claude Code leads: scope, split, route, inspect diffs, validate, report. Delegate heavy work to Codex. Work directly only when the user explicitly requests it. User and project instructions take precedence.

## Routing

Use `scripts/shepherd-run.sh <tier> <effort> <read|write> <prompt-file> [workdir] [--escalate]` from this skill directory. Model names come from `config/shepherd.env` in the checkout; copied installations include their own config. Environment variables override defaults; `SHEPHERD_CONFIG` selects another trusted config.

| Tier | Work | Effort policy |
| --- | --- | --- |
| luna | Easy fixes, quick investigation, small implementation | low–high; xhigh/max only with --escalate, within configured ceiling |
| sol | Broad coding, complex bugs, independent review | medium/high; xhigh only with --escalate; never low/max |
| astra | Last resort after lower tiers fail | Always low; --escalate required |
| reserve | Alternative when another tier is unavailable | low–max within configured ceiling |

Escalate only after evidence of insufficient output: luna high, luna xhigh/max with escalation, sol high, sol xhigh with escalation, astra low with escalation. Explain last-resort use. Config can tighten ceilings. Use sol high for sensitive implementation and an independent sol high read task for review. Claude owns final security and data decisions.

## Task contract

Announce tier and purpose. Write a prompt file with task, named target files, minimal context, constraints, and measurable acceptance criteria. Keep each task small enough for one timeout window. Investigation and review use read; implementation uses write. Never assign concurrent writes to the same files. Worker reads project instructions. Nested delegation is disabled.

```text
Task: <one bounded outcome>
Target files: <exact paths>
Context: <relevant facts and decisions>
Constraints: <scope, project rules, checks available>
Acceptance criteria: <commands and expected results>
```

Wrapper adds scope rules, time budget, and report format:

```text
STATUS: complete | partial | failed
CHANGED FILES: path:line-range and change, or none
CRITERIA: PASS/FAIL per criterion with evidence
CHECKS RUN: command and result
OPEN ITEMS / BLOCKERS: remaining bounded subtasks, or none
SUGGESTIONS (not applied): out-of-scope ideas, or none
```

## Recovery and responsibility

- Exit 124 means partial work, even if resume returns a report. Recovery is read-only, low effort, report-only. Continue from reported open items; never blindly restart. A second timeout on the same task requires reporting the blocker to the user.
- Exit 75 means quota exhaustion. Try reserve once unless already using reserve. If also blocked, use a Claude subagent available in your environment. If that fails, stop and report unfinished work; lead implements only with explicit user authorization. Claude-specific tools may also need a Claude worker.
- Exit 76 means capacity remains unavailable after one bounded resume attempt. Route to reserve or luna. Exit 77 means the sol slot wait expired; retry later or choose another suitable tier. Never bypass the configured sol limit.
- Inspect every diff and run required checks. Exit 0 alone does not establish acceptance. Treat partial/failed reports as incomplete. For write tasks, the wrapper shows workspace diff statistics and runs optional `POST_WRITE_CHECK` in the workdir. Statistics can include pre-existing changes.
- Protect secrets and review sandbox boundaries. Do not approve destructive data changes without the project's required authorization. Keep logs private; they may contain prompts and source. No session deletion or automatic publication.
