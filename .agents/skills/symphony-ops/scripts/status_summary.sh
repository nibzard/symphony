#!/usr/bin/env bash
set -euo pipefail

service="${1:-symphony-prism.service}"
api_url="${2:-http://127.0.0.1:4001/api/v1/state}"

active_state="$(systemctl --user show "$service" -p ActiveState --value 2>/dev/null || true)"
sub_state="$(systemctl --user show "$service" -p SubState --value 2>/dev/null || true)"
main_pid="$(systemctl --user show "$service" -p MainPID --value 2>/dev/null || true)"
exec_start="$(systemctl --user show "$service" -p ExecMainStartTimestamp --value 2>/dev/null || true)"

printf 'service=%s\n' "$service"
printf 'active_state=%s\n' "${active_state:-unknown}"
printf 'sub_state=%s\n' "${sub_state:-unknown}"
printf 'main_pid=%s\n' "${main_pid:-unknown}"
printf 'started=%s\n' "${exec_start:-unknown}"

api_body="$(curl -fsS "$api_url" 2>/dev/null || true)"
if [[ -z "$api_body" ]]; then
  printf 'api_state=unreachable\n'
  exit 0
fi

printf 'api_state=reachable\n'

if command -v jq >/dev/null 2>&1; then
  printf 'runtime_started_at=%s\n' "$(jq -r '.runtime.runtime.started_at // "unknown"' <<<"$api_body")"
  printf 'workflow_path=%s\n' "$(jq -r '.runtime.workflow.path // "unknown"' <<<"$api_body")"
  printf 'running=%s\n' "$(jq -r '.counts.running // ((.running // []) | length)' <<<"$api_body")"
  printf 'retrying=%s\n' "$(jq -r '.counts.retrying // ((.retrying // []) | length)' <<<"$api_body")"
  printf 'recent_sessions=%s\n' "$(jq -r '(.history.recent_sessions // []) | length' <<<"$api_body")"
else
  printf 'api_body=%s\n' "$api_body"
fi
