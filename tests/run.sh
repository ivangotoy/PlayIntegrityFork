#!/bin/sh
# Offline test suite: declared checks plus stub-driven runs of the real module scripts.
# Usage: sh tests/run.sh   (TEST_SH selects the shell for module scripts, default sh)
# Scratch goes under $TMPDIR. Nothing under module/ is created or changed.

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_SH="${TEST_SH:-sh}"
BASE_PATH="$PATH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pif-tests.XXXXXX")" || exit 2
[ -n "$KEEP_WORK" ] || trap 'rm -rf "$WORK"' EXIT INT TERM
export ROOT TEST_SH BASE_PATH WORK

. "$ROOT/tests/lib.sh"

echo "# shell under test: $TEST_SH ($(command -v "$TEST_SH"))"
for c in "$ROOT"/tests/cases/*.sh; do
    CASE="$(basename "$c" .sh)"
    . "$c"
done

echo "# pass $PASS fail $FAIL skip $SKIP"
[ "$FAIL" -eq 0 ]
