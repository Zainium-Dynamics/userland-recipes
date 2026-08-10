#!/bin/sh
# ci/changed-packages.sh — print one line per top-level package directory
# touched by this MR/push, so CI only builds what actually changed
# (thousands of recipes in this repo, no reason to rebuild all of them
# on every pipeline).

set -eu

if [ -n "${BASE_SHA:-}" ]; then
    BASE="$BASE_SHA"
else
    BASE="HEAD~1"
fi

git diff --name-only "$BASE"...HEAD -- . \
    | cut -d/ -f1 \
    | sort -u \
    | while read -r dir; do
        [ -f "$dir/ZEXBUILD" ] && echo "$dir"
      done
