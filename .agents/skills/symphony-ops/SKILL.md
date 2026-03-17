---
name: symphony-ops
description: Start, restart, monitor, and recover a Symphony runtime safely; use for service health checks, idle-or-stuck investigations, runtime verification after changes, and routine operational checks.
---

# Symphony Ops

Use this skill for live Symphony operations. Prefer it when the task is to start
or restart a runtime, check whether Symphony is healthy, explain why it is idle,
verify the service environment, or confirm that work is being picked up after a
change.

Primary runtime mode is `systemd --user`. Treat `tmux` as legacy or fallback.

If the task is primarily about tracing one issue/session through logs, use the
repo `debug` skill after doing the basic health checks here.

## Workflow

1. Identify the runtime target.
2. Check service health before changing anything.
3. Compare live runtime state with tracker reality.
4. Verify environment-backed configuration if behavior looks wrong.
5. Restart only when the evidence justifies it.
6. After any restart, verify dispatch and health immediately.

## Runtime Target

Default to the user service name the repo actually runs, usually
`symphony-prism.service`.

Useful commands:

```bash
systemctl --user status symphony-prism.service
journalctl --user -u symphony-prism.service -n 100
```

For a compact summary, use `scripts/status_summary.sh`.

## Health Check First

Before restarting, check all of these:

- user service state via `systemctl --user status`
- API/dashboard reachability, usually `http://127.0.0.1:4001/api/v1/state`
- whether the runtime shows `running`, `retrying`, and recent session history
- recent journal output for obvious auth, boot, or polling failures

Use:

```bash
/home/agent/symphony/.agents/skills/symphony-ops/scripts/status_summary.sh symphony-prism.service
```

If the API is healthy but the system is idle, do not assume there is a bug yet.
First confirm whether there are actually any eligible Linear issues.

## Idle Or Stuck Triage

When Symphony appears idle:

1. Confirm current runtime state from the API.
2. Check recent logs for polling/auth/config failures.
3. Compare with tracker reality. An issue being visible in some Linear view is
   not enough; confirm it is eligible under the active `WORKFLOW.md`.
4. If the runtime is alive but not dispatching, verify service environment and
   tracker configuration before restarting.

Common causes:

- no eligible issues in the configured project/workflow
- missing env-backed tracker credentials in the service environment
- a restart that brought the web/API back but left the orchestrator unable to
  authenticate or poll meaningfully
- stale local history causing a dashboard mismatch that is not a live scheduler
  problem

Read `references/failure-signatures.md` for exact signatures.

## Verify Service Environment

If `WORKFLOW.md` resolves secrets from environment variables such as
`$LINEAR_API_KEY`, verify the running service actually has them.

Use:

```bash
/home/agent/symphony/.agents/skills/symphony-ops/scripts/verify_service_env.sh \
  symphony-prism.service LINEAR_API_KEY
```

Do not assume your current shell environment matches the service environment.
This was a real failure mode when `tmux` sessions inherited stale variables.

## Restart Procedure

Restart only when one of these is true:

- the service is down or unhealthy
- the orchestrator is clearly not dispatching despite eligible work
- configuration or code changes require a reload
- local history was repaired and needs to be reloaded into memory

Preferred command:

```bash
systemctl --user restart symphony-prism.service
```

Avoid restarting during active work unless the recovery value outweighs the
interruption.

## Post-Restart Verification

Always verify all of the following after a restart:

1. `systemctl --user status` is `active`
2. API state responds successfully
3. recent logs show successful boot
4. if eligible work exists, Symphony dispatches it within the poll window
5. if no work exists, confirm the runtime is idle for the right reason

Do not stop at "the process is up". A healthy API with no dispatch can still
mask an auth or configuration problem.

## History Reconciliation

Use runtime refresh and history reconciliation for different problems:

- `Refresh Runtime`: force a fresh poll/reconcile of live scheduler state
- `Reconcile History`: repair persisted historical issue-state fields from
  Linear when the dashboard shows stale historical state

History mismatches do not necessarily mean live orchestration is broken.

## Communication Rules

- Use absolute UTC timestamps when explaining incident timelines.
- Distinguish clearly between live runtime state and persisted history.
- When reporting "nothing is happening", state whether the cause is:
  - no eligible work
  - service/env/auth failure
  - scheduler/runtime failure
  - dashboard/history mismatch only

## References

- `references/operations.md`: standard commands and decision flow
- `references/failure-signatures.md`: common failure modes and what they mean
