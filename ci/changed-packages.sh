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

# "$dir/ZEXBUILD" not existing for a given changed top-level path (e.g.
# a push that only touches .github/ or ci/, no package directory at
# all) is a completely normal outcome, not a failure — but `[ -f ... ]`
# failing IS what a bare `&&`-only body leaves as the while loop's own
# exit status once it hits EOF, which then becomes this whole
# pipeline's (and the script's) exit status under `set -e`. `|| true`
# makes "not a package dir" and "is a package dir" both count as a
# successful iteration; only a real git-diff failure above should ever
# fail this script.
cut -d/ -f1 < "$diff_out" \
    | sort -u \
    | while read -r dir; do
        [ -f "$dir/ZEXBUILD" ] && echo "$dir"
        true
      done
