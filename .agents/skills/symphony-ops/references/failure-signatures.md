# Failure Signatures

## API Healthy, Nothing Dispatches

Likely causes:

- no eligible issues under the active workflow
- missing service environment variables for tracker auth
- scheduler/runtime problem after restart

Check:

```bash
/home/agent/symphony/.agents/skills/symphony-ops/scripts/status_summary.sh symphony-prism.service
/home/agent/symphony/.agents/skills/symphony-ops/scripts/verify_service_env.sh symphony-prism.service LINEAR_API_KEY
journalctl --user -u symphony-prism.service -n 100
```

## Service Running But Logs Show Tracker Auth Errors

Typical meaning:

- `WORKFLOW.md` expects an env-backed secret, but the service process does not
  have it

Example class of error:

- missing Linear API token or failed tracker authentication during polling

Fix:

- repair the service environment file or unit configuration
- restart the user service
- verify dispatch afterward

## Dashboard Shows Old Issue States

Typical meaning:

- persisted history is stale or predates a history metadata fix
- live Linear state may already be correct

Fix:

- use history reconciliation
- restart only if the repaired file must be reloaded into memory

## Restart Succeeds But Issue Still Does Not Run

Likely causes:

- issue is no longer eligible
- project or workflow filter excludes it
- tracker state changed during the incident window

Check:

- current issue state in Linear
- active `WORKFLOW.md`
- live API state after the restart
