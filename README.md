# Shepherd

```text
        /\_/\\
       ( o.o )   SHEPHERD
        > ^ <    Keep Claude thinking; send the heavy lifting to the pack.
```

Claude Code is the shepherd. Codex CLI workers are the pack. Shepherd routes bounded investigation, coding, and review tasks to Codex, with model tiers, effort ceilings, sandbox modes, and time limits.

## Why

Keep Claude's quota for planning, routing, and final review. Send heavy work to Codex CLI. Claude remains responsible for scope, diff inspection, validation, and the final report.

## How it works

```text
User task
   |
   v
Claude Code: scope and split
   |
   v
Shepherd: tier + effort + read/write + time limit
   |
   v
Codex CLI worker: bounded task in project directory
   |
   v
Claude Code: inspect diff, run checks, accept or report
```

## Install in 60 seconds

```sh
SHEPHERD_REPO_URL=https://github.com/BeNTz16/shepherd.git bash install.sh
```

Run this from a Shepherd checkout. Installer clones to `${XDG_DATA_HOME:-$HOME/.local/share}/shepherd` and installs a symlink at `$HOME/.claude/skills/shepherd`. Set `SHEPHERD_CHECKOUT` or `SHEPHERD_INSTALL_DIR` to change those paths. Set `SHEPHERD_INSTALL_MODE=copy` to copy files instead. Requires `git` for a remote clone.

## Use it

1. Install Codex CLI and sign in. The runner also needs `timeout`, `flock`, and `setsid` (util-linux).
2. Copy `templates/AGENTS.delegation.md` into your project as `AGENTS.md`. Review its delegation rules.
3. In Claude Code, give it a bounded task with named target files and acceptance criteria. Example: “Investigate why `src/cache.php` returns stale values. Read only; report root cause with file and line, plus a minimal fix proposal.”
4. Claude routes investigation and review in `read` mode, implementation in `write` mode. It inspects changes and runs project checks before accepting.

The prompt file must state task, exact target files, relevant context, constraints, and measurable acceptance criteria. Do not put secrets in prompts.

## Tiers

| Tier | Use | Effort |
| --- | --- | --- |
| `luna` | Easy fixes, quick investigation, small implementation | `low`–`high`; `xhigh`/`max` need `--escalate` |
| `sol` | Broad coding, complex bugs, independent review | `medium`/`high`; escalated `xhigh`; never `low`/`max` |
| `astra` | Last resort after lower tiers fail | `low` only; requires `--escalate` |
| `reserve` | Alternative when another tier is unavailable | `low`–`max`, within configured ceiling |

Model names in the example config are examples. Change them to models available in your Codex account.

## Command reference

```text
"$HOME/.claude/skills/shepherd/scripts/shepherd-run.sh" <luna|sol|astra|reserve> <low|medium|high|xhigh|max> <read|write> <prompt-file> [workdir] [--escalate] [--critical]
```

The installer makes the runner executable in both install modes. Use the path above after a default install; substitute `SHEPHERD_INSTALL_DIR` for a custom location. `workdir` defaults to the current directory. `--escalate` and `--critical` may follow the prompt file or workdir. `read` uses Codex `read-only`; `write` uses `workspace-write`. The runner disables nested agents and does not skip the configured `sol` concurrency limit.

| Option | Effect |
| --- | --- |
| `--escalate` | Select escalated tier ceiling and timeout; required for `astra`. |
| `--critical` | Require `SHEPHERD_CRITICAL_TIER` (default `sol`) and at least `SHEPHERD_CRITICAL_MIN_EFFORT` (default `high`); does not enable escalation. |
| `SHEPHERD_CONFIG` | Load another trusted shell config instead of the bundled config. |

For a write task, the runner prints diff statistics and runs `POST_WRITE_CHECK` when set. Logs and reports are stored under `${SHEPHERD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shepherd}` with restrictive permissions.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Codex task and any configured post-write check succeeded. Still inspect the report and diff. |
| `2` | Invalid arguments, config, tier, effort, mode, prompt, or workdir. |
| `75` | Codex quota exhausted. Try `reserve` once, then use the documented Claude fallback. |
| `76` | Codex capacity remained unavailable after one resume attempt, or no session was available to resume. |
| `77` | `sol` concurrency slot wait expired. |
| `124` | Task timed out; remaining work is partial. |
| `127` | Required executable missing: `codex`, `timeout`, `flock`, or `setsid`. |
| Other | Codex or `POST_WRITE_CHECK` exit code propagated by the runner. |

## Configuration

Environment variables override bundled defaults. `config/shepherd.env` is trusted shell code; only load a config you trust.

Without `--escalate`, the `sol` and `luna` effort ceiling is fixed at `high`. With `--escalate`, `SHEPHERD_SOL_MAX_EFFORT` and `SHEPHERD_LUNA_MAX_EFFORT` set their ceilings (defaults: `xhigh` and `max`). `sol` still rejects `low` and `max`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SHEPHERD_MODEL_LUNA` | `gpt-6-luna` | Model for `luna`. |
| `SHEPHERD_MODEL_SOL` | `gpt-6.1-sol` | Model for `sol`. |
| `SHEPHERD_MODEL_ASTRA` | `gpt-6-astra` | Model for `astra`. |
| `SHEPHERD_MODEL_RESERVE` | `gpt-reserve` | Model for `reserve`. |
| `SHEPHERD_LUNA_MAX_EFFORT` | `max` | `luna` ceiling with `--escalate`; otherwise ceiling is `high`. |
| `SHEPHERD_SOL_MAX_EFFORT` | `xhigh` | `sol` ceiling with `--escalate`; otherwise ceiling is `high`. |
| `SHEPHERD_RESERVE_MAX_EFFORT` | `max` | `reserve` ceiling. |
| `SHEPHERD_TIMEOUT` | `420` | Normal task timeout, seconds. |
| `SHEPHERD_ESCALATED_TIMEOUT` | `600` | Escalated task timeout, seconds. |
| `SHEPHERD_TIMEOUT_MAX` | `420` | Maximum normal timeout, seconds. |
| `SHEPHERD_ESCALATED_TIMEOUT_MAX` | `600` | Maximum escalated timeout, seconds. |
| `SHEPHERD_RESUME_TIMEOUT` | `90` | Resume timeout, seconds. |
| `SHEPHERD_KILL_AFTER` | `10` | Seconds before timeout sends kill signal. |
| `SHEPHERD_CAPACITY_WAIT` | `45` | Wait before resuming after capacity error, seconds. |
| `SHEPHERD_SOL_LIMIT` | `2` | Concurrent `sol` tasks allowed. |
| `SHEPHERD_SLOT_WAIT` | `1800` | Maximum wait for a `sol` slot, seconds. |
| `SHEPHERD_READ_SOFT_PERCENT` | `85` | Soft deadline percentage for read tasks. |
| `SHEPHERD_WRITE_SOFT_PERCENT` | `80` | Soft deadline percentage for write tasks. |
| `POST_WRITE_CHECK` | empty | Trusted shell command run in workdir after write tasks. |
| `SHEPHERD_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/shepherd` | Private logs, reports, and slot locks. |
| `SHEPHERD_REPO_URL` | empty | Clone URL when installing from a remote repository. |
| `SHEPHERD_CHECKOUT` | `${XDG_DATA_HOME:-$HOME/.local/share}/shepherd` | Checkout path used with `SHEPHERD_REPO_URL`. |
| `SHEPHERD_INSTALL_DIR` | `$HOME/.claude/skills/shepherd` | Installed skill path. |
| `SHEPHERD_INSTALL_MODE` | `symlink` | `symlink` or `copy`. |
| `XDG_DATA_HOME` | unset | Base path for default checkout. |
| `XDG_STATE_HOME` | unset | Base path for default state directory. |

## Security

- `read` grants read-only sandbox access. `write` grants workspace-write access. Use write mode only for implementation tasks.
- Keep passwords, API keys, tokens, and private data out of prompts. Logs contain prompts and source; protect the state directory.
- Shepherd config is shell code. Use only trusted config files. `POST_WRITE_CHECK` is also executed as a shell command.
- Review diffs and checks. Claude owns final security and data decisions. Follow project approval rules for destructive changes.

## Early release (v0.1)

Shepherd is an early release. It may have defects and can be improved. Review worker output and verify important changes.

## Roadmap

- Improve setup and configuration guidance.
- Add more operational examples as real use cases emerge.
- Refine tier defaults from measured results.

## Contributing

Open an issue or pull request with the problem, proposed change, and checks run. Keep tasks bounded and avoid adding configuration without a concrete need.

## Related projects

- [sheepdog](https://github.com/BeNTz16/sheepdog): multi-session coordination board.
- [wolfhound](https://github.com/BeNTz16/wolfhound): security scanning skill.

These are separate, optional projects. Shepherd works without them.

## License

MIT
