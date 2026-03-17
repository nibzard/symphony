#!/usr/bin/env bash
set -euo pipefail

service="${1:-symphony-prism.service}"
shift || true

if [[ "$#" -eq 0 ]]; then
  vars=(LINEAR_API_KEY)
else
  vars=("$@")
fi

pid="$(systemctl --user show "$service" -p MainPID --value)"
if [[ -z "$pid" || "$pid" == "0" ]]; then
  printf 'service=%s\n' "$service"
  printf 'error=no running main pid\n' >&2
  exit 1
fi

env_dump="$(tr '\0' '\n' <"/proc/$pid/environ")"

printf 'service=%s\n' "$service"
printf 'main_pid=%s\n' "$pid"

missing=0
for var_name in "${vars[@]}"; do
  if grep -q "^${var_name}=" <<<"$env_dump"; then
    printf '%s=present\n' "$var_name"
  else
    printf '%s=missing\n' "$var_name"
    missing=1
  fi
done

exit "$missing"
