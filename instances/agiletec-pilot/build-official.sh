#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ABSOLUTE_OUTPUT_DIRECTORY" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output_dir=$(node -e 'console.log(require("node:path").resolve(process.argv[1]))' "$1")

case "$output_dir/" in
  "$repo_root/"*)
    echo "output directory must be outside the repository" >&2
    exit 64
    ;;
esac

command -v docker >/dev/null 2>&1 || {
  echo "docker is required; do not install host Elixir from this script" >&2
  exit 69
}

upstream_url=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).runtime.upstreamRepository' "$script_dir/instance.json")
upstream_commit=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).runtime.commit' "$script_dir/instance.json")
build_image=$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).runtime.buildImage' "$script_dir/instance.json")

build_root=$(mktemp -d "${TMPDIR:-/tmp}/airis-symphony-build.XXXXXX")
cleanup() {
  rm -rf -- "$build_root"
}
trap cleanup EXIT HUP INT TERM

source_dir="$build_root/source"
git init --quiet "$source_dir"
git -C "$source_dir" remote add origin "$upstream_url"
git -C "$source_dir" fetch --quiet --depth 1 origin "$upstream_commit"
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD

actual_commit=$(git -C "$source_dir" rev-parse HEAD)
if [ "$actual_commit" != "$upstream_commit" ]; then
  echo "upstream commit mismatch: expected $upstream_commit, got $actual_commit" >&2
  exit 65
fi

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp/symphony-build-home \
  --volume "$source_dir:/work" \
  --workdir /work/elixir \
  "$build_image" \
  sh -euc 'mix local.hex --force && mix local.rebar --force && mix setup && mix build'

mkdir -p "$output_dir"
cp "$source_dir/elixir/bin/symphony" "$output_dir/symphony"
chmod 0755 "$output_dir/symphony"
node -e '
  const fs = require("node:fs")
  const path = require("node:path")
  const output = {
    repository: process.argv[2],
    commit: process.argv[3],
    buildImage: process.argv[4],
  }
  fs.writeFileSync(path.join(process.argv[1], "build-manifest.json"), `${JSON.stringify(output, null, 2)}\n`)
' "$output_dir" "$upstream_url" "$upstream_commit" "$build_image"

echo "built official Symphony at $output_dir/symphony"
