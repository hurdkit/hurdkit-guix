#!/bin/sh
# Run libwayland's own tests, which wayland-hurd installs in its "tests"
# output, and report them as TAP. Each program runs all of its cases and
# checks, as upstream does, that no case leaves a descriptor open.
set -u
names='array-test client-test connection-test display-test event-loop-test
list-test map-test message-test os-wrappers-test queue-test resources-test
signal-test socket-test'
dir=${WAYLAND_TEST_DIR:-/run/current-system/profile/libexec/wayland-tests}
export TEST_BUILD_DIR="$dir"
number=0
status=0
for name in $names; do
    number=$((number + 1))
    if output=$(timeout 120 "$dir/$name" 2>&1); then
        echo "ok $number - $name"
    else
        echo "not ok $number - $name"
        status=1
    fi
    printf '%s\n' "$output" | sed 's/^/# /'
done
echo "1..$number"
exit "$status"
