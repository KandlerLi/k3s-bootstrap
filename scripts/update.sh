#!/usr/bin/env bash
# After merging a PR: fresh main, then roll-out.sh with the same arguments. See README.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "${script_dir}")"

# Would otherwise roll out unmerged changes.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "update.sh: uncommitted changes -- commit or stash them first" >&2
  exit 1
fi

git checkout main
git pull --ff-only origin main

exec scripts/roll-out.sh "$@"
