# Symphony Ops Reference

## Standard Commands

```bash
# Service state
systemctl --user status symphony-prism.service
systemctl --user restart symphony-prism.service

# Logs
journalctl --user -u symphony-prism.service -n 100
journalctl --user -u symphony-prism.service -f

# Live API state
curl -fsS http://127.0.0.1:4001/api/v1/state | jq

# Compact helpers
/home/agent/symphony/.agents/skills/symphony-ops/scripts/status_summary.sh symphony-prism.service
/home/agent/symphony/.agents/skills/symphony-ops/scripts/verify_service_env.sh symphony-prism.service LINEAR_API_KEY
```

## Decision Flow

1. Check service status.
2. Check API state.
3. Check recent logs.
4. If idle, confirm whether eligible issues actually exist under the active
   workflow.
5. If behavior looks wrong, verify service environment for required variables.
6. Restart only after identifying a concrete reason.
7. Verify dispatch or justified idleness after restart.

## What To Compare

- `systemctl --user status`: process health
- `/api/v1/state`: orchestrator view
- `journalctl`: startup/auth/polling errors
- Linear under the configured workflow/project: actual candidate truth
- persisted history: historical view only

## Good Outcome Patterns

- Service is `active`, API responds, and there are no candidates.
- Service is `active`, API responds, and `running` increases after a restart.
- History reconcile changes dashboard history without affecting live work.

## Bad Outcome Patterns

- Service is `active` but logs show missing `LINEAR_API_KEY`.
- API responds but `running=0` while eligible issues exist and no retries are
  queued.
- Dashboard history looks wrong, and the operator mistakes that for live state.
