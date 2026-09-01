#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
  echo "usage: run-instance-lane.sh <instance.json> <lane> <repo-checkout> <symphony-binary> <config-root> <log-root>" >&2
  exit 64
fi

manifest=$1
lane=$2
checkout=$3
binary=$4
config_root=$5
log_root=$6
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

test -n "${LINEAR_API_KEY:-}" || { echo "missing host environment variable: LINEAR_API_KEY" >&2; exit 78; }
test -n "${SYMPHONY_WORKSPACE_ROOT:-}" || { echo "missing host environment variable: SYMPHONY_WORKSPACE_ROOT" >&2; exit 78; }
test -n "${SYMPHONY_REVIEWER_LOGIN:-}" || { echo "missing host environment variable: SYMPHONY_REVIEWER_LOGIN" >&2; exit 78; }
test -x "$binary" || { echo "Symphony binary is not executable: $binary" >&2; exit 78; }
test -d "$checkout" || { echo "repository checkout does not exist: $checkout" >&2; exit 78; }
test -d "$config_root" || { echo "config root does not exist: $config_root" >&2; exit 78; }
test -d "$log_root" || { echo "log root does not exist: $log_root" >&2; exit 78; }

node "$script_dir/audit-repository-boundary.mjs" "$manifest" "$lane" "$checkout"
node "$script_dir/verify-runtime-artifact.mjs" "$manifest" "$binary"

workflow="$config_root/$lane.WORKFLOW.md"
node "$script_dir/render-lane-workflow.mjs" "$manifest" "$lane" "$checkout" "$workflow"

exec "$binary" "$workflow" \
  --logs-root "$log_root" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
