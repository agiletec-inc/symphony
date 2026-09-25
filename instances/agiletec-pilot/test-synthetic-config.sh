#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ABSOLUTE_BUILD_DIRECTORY" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
build_dir=$(node -e 'console.log(require("node:path").resolve(process.argv[1]))' "$1")
artifact="$build_dir/symphony"
manifest="$build_dir/build-manifest.json"

node "$repo_root/scripts/verify-instance.mjs" "$script_dir/instance.json" --runtime
node "$repo_root/scripts/verify-runtime-artifact.mjs" "$script_dir/instance.json" "$artifact"

test -x "$artifact" || {
  echo "missing executable: $artifact" >&2
  exit 66
}
test -f "$manifest" || {
  echo "missing build manifest: $manifest" >&2
  exit 66
}

expected_commit=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).runtime.commit' "$script_dir/instance.json")
actual_commit=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).commit' "$manifest")
build_image=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).buildImage' "$manifest")
test "$actual_commit" = "$expected_commit" || {
  echo "artifact was not built from the pinned commit" >&2
  exit 65
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/airis-symphony-synthetic.XXXXXX")
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$test_root/workspaces" "$test_root/logs"

set +e
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp/symphony-test-home \
  --env SYMPHONY_WORKSPACE_ROOT=/runtime/workspaces \
  --volume "$artifact:/runtime/symphony:ro" \
  --volume "$script_dir/fixtures/synthetic-workflow.md:/runtime/WORKFLOW.md:ro" \
  --volume "$test_root/workspaces:/runtime/workspaces" \
  --volume "$test_root/logs:/runtime/logs" \
  "$build_image" \
  timeout --signal=TERM 5 /runtime/symphony /runtime/WORKFLOW.md \
    --logs-root /runtime/logs \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails
status=$?
set -e

if [ "$status" -ne 124 ]; then
  echo "synthetic Symphony process exited before the bounded test timeout (status=$status)" >&2
  exit 1
fi

echo "synthetic memory-tracker config stayed healthy for the bounded test window"
