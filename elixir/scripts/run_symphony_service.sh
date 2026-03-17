#!/bin/bash
set -euo pipefail

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

workflow_path="${1:?workflow path is required}"

exec /home/agent/symphony/elixir/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$workflow_path"
