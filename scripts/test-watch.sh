#!/bin/bash
# Runs a test command and, if it is still going after WATCH_SECONDS (480),
# prints where each test process is stuck and fails. `swift test` holds its
# output until the process ends, so a stalled run otherwise shows nothing
# until the job's own timeout.
#
#   scripts/test-watch.sh swift test --package-path ThrowingWoodKit
set -uo pipefail
limit=${WATCH_SECONDS:-480}
"$@" &
run=$!
waited=0
while kill -0 "$run" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
  sleep 5
  waited=$((waited + 5))
done
if ! kill -0 "$run" 2>/dev/null; then
  wait "$run"
  exit $?
fi
echo "Still running after ${waited}s. Where each test process is:" >&2
for pid in $(pgrep -f 'swiftpm-testing|swiftpm-xctest|PackageTests' || true); do
  echo "== process $pid: $(ps -o command= -p "$pid" | cut -c1-160)" >&2
  sample "$pid" 3 -mayDie 2>/dev/null | sed -n '/^Call graph:/,/^Total number in stack/p' | head -400 >&2
  kill "$pid" 2>/dev/null || true
done
kill "$run" 2>/dev/null || true
exit 1
