#!/bin/sh
# ci/changed-packages.sh — print one line per top-level package directory
# touched by this MR/push, so CI only builds what actually changed
# (thousands of recipes in this repo, no reason to rebuild all of them
# on every pipeline).

set -eu

# git's empty-tree hash — diffing against it makes every file in HEAD show
# up as "changed", i.e. build everything. Used as the fallback whenever
# there's no real prior commit to diff against.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

if [ -n "${BASE_SHA:-}" ] && [ "$BASE_SHA" != "0000000000000000000000000000000000000000" ]; then
    BASE="$BASE_SHA"
elif git rev-parse --verify -q HEAD~1 >/dev/null; then
    BASE="HEAD~1"
else
    # First commit in the repo, or (via BASE_SHA=000...0) the very first
    # push of a repo's full history — nothing to diff against, so treat
    # everything as new.
    BASE="$EMPTY_TREE"
fi

git diff --name-only "$BASE"...HEAD -- . \
    | cut -d/ -f1 \
    | sort -u \
    | while read -r dir; do
        [ -f "$dir/ZEXBUILD" ] && echo "$dir"
      done
