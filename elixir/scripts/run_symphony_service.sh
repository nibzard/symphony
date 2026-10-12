#!/bin/bash
set -euo pipefail

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

workflow_path="${1:?workflow path is required}"
history_path="${2:-}"

history_opts=""
if [ -n "$history_path" ]; then
  history_opts="--eval symphony_elixir observability_history_path='$history_path'"
fi

exec /home/agent/symphony-loam/elixir/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  $history_opts \
  "$workflow_path"
