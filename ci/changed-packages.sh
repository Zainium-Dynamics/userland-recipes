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

if [ -n "${BASE_SHA:-}" ] && [ "$BASE_SHA" != "0000000000000000000000000000000000000000" ] \
    && git rev-parse --verify -q "${BASE_SHA}^{commit}" >/dev/null 2>&1; then
    BASE="$BASE_SHA"
elif git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
    # Also covers BASE_SHA being set but somehow unresolvable in this
    # checkout (e.g. an unexpected shallow/partial fetch) — falls back
    # to a same-push single-commit diff instead of hard-failing outright.
    BASE="HEAD~1"
else
    # First commit in the repo, or (via BASE_SHA=000...0) the very first
    # push of a repo's full history — nothing to diff against, so treat
    # everything as new.
    BASE="$EMPTY_TREE"
fi

# Not piped straight into cut/sort/while — in POSIX sh (no pipefail), a
# pipeline's exit status is its LAST command's, so a failing `git diff`
# would be silently swallowed: this script would print nothing and
# still exit 0, making the caller's `for pkg in $(...)` loop over zero
# packages and the whole release report a (fake) success having built
# nothing. Same bug class already fixed once in ci/build.sh's pack step.
diff_out="$(mktemp)"
trap 'rm -f "$diff_out"' EXIT
if ! git diff --name-only "$BASE"...HEAD -- . > "$diff_out" 2>&1; then
    echo "changed-packages.sh: git diff $BASE...HEAD failed:" >&2
    cat "$diff_out" >&2
    exit 1
fi

cut -d/ -f1 < "$diff_out" \
    | sort -u \
    | while read -r dir; do
        [ -f "$dir/ZEXBUILD" ] && echo "$dir"
      done
