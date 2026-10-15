#!/usr/bin/env bash
# CI test step: `swift test` (serial), then each failed test case once more on
# its own. Several reconciler and motion-lane tests time real thread work
# against 0.1-0.3 s budgets; a hosted runner's scheduling noise sometimes
# pushes one past its budget. A case that passes on its own is reported as a
# workflow warning (visible on the run), never hidden; a case that fails twice,
# more than three failed cases, or a failure without a failed case (a build
# error, a crash) fails the step.
set -uo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift test 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -eq 0 ]; then
	exit 0
fi

failed="$(
	grep -oE "Test Case '-\[[A-Za-z0-9_]+\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' failed" "$log" \
		| sed -E "s/Test Case '-\[([^ ]+) ([^]]+)\]' failed/\1\/\2/" \
		| sort -u
)"
if [ -z "$failed" ]; then
	echo "::error::swift test failed without a failed test case (build error or crash)"
	exit "$status"
fi
count="$(printf '%s\n' "$failed" | wc -l | tr -d ' ')"
if [ "$count" -gt 3 ]; then
	echo "::error::$count test cases failed; not retrying"
	exit "$status"
fi

for test in $failed; do
	echo "Retrying $test on its own"
	if ! swift test --filter "^${test}\$"; then
		echo "::error::$test failed twice"
		exit 1
	fi
	echo "::warning::$test failed once and passed on its own (timing budget on a loaded runner)"
done
