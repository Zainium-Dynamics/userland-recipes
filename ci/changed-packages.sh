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

# Repo-state diagnostics, always printed — the Alpine-container release
# run has twice landed on the EMPTY_TREE fallback despite a real,
# resolvable BASE_SHA (and HEAD~1 too), which shouldn't happen on a
# fetch-depth:0 checkout and doesn't reproduce locally. Until that's
# actually understood, print everything relevant so the next occurrence
# is diagnosable from the CI log instead of guessed at.
echo "-- changed-packages.sh: repo diagnostics --" >&2
echo "pwd: $(pwd)" >&2
git rev-parse --show-toplevel >&2 2>&1 || echo "  (show-toplevel failed)" >&2
git rev-parse HEAD >&2 2>&1 || echo "  (rev-parse HEAD failed)" >&2
git log --oneline -5 >&2 2>&1 || echo "  (log failed)" >&2
git count-objects -v >&2 2>&1 || echo "  (count-objects failed)" >&2
echo "BASE_SHA env: ${BASE_SHA:-<unset>}" >&2
echo "-- end diagnostics --" >&2

# Resolves $1 to a commit; on failure prints git's own (real, not -q
# suppressed) error text to stdout so the caller can log *why*.
resolve() {
    git rev-parse --verify "$1^{commit}" 2>&1
}

BASE=""
if [ -n "${BASE_SHA:-}" ] && [ "$BASE_SHA" != "0000000000000000000000000000000000000000" ]; then
    if out="$(resolve "$BASE_SHA")"; then
        BASE="$BASE_SHA"
    else
        echo "changed-packages.sh: BASE_SHA=$BASE_SHA did not resolve: $out" >&2
    fi
fi
if [ -z "$BASE" ]; then
    if out="$(resolve HEAD~1)"; then
        BASE="HEAD~1"
    else
        echo "changed-packages.sh: HEAD~1 did not resolve: $out" >&2
    fi
fi
if [ -z "$BASE" ]; then
    # First commit in the repo, or (via BASE_SHA=000...0) the very first
    # push of a repo's full history — nothing to diff against, so treat
    # everything as new.
    BASE="$EMPTY_TREE"
fi
echo "changed-packages.sh: using BASE=$BASE" >&2

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
