#!/usr/bin/env bash
# TAP tests for the dependency-free Tcl PPM checker.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
command -v tclsh >/dev/null 2>&1 || { echo '1..0 # SKIP tclsh is required'; exit 0; }
PPM=(tclsh "$REPO_ROOT/scripts/ppm_check.tcl")
# Three by two: four red pixels, one green pixel, one blue pixel.
printf 'P6\n# generated fixture\n3 2\n255\n' > "$TEST_DIR/solid.ppm"
printf '\377\000\000\377\000\000\000\377\000\377\000\000\000\000\377\377\000\000' >> "$TEST_DIR/solid.ppm"
cp "$TEST_DIR/solid.ppm" "$TEST_DIR/changed.ppm"
printf '\377\377\377' | dd of="$TEST_DIR/changed.ppm" bs=1 seek=31 conv=notrunc status=none
echo '1..8'
failures=0
number=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then echo "ok $number - $description"; else echo "not ok $number - $description"; failures=$((failures + 1)); fi
}
check_fails() {
    local description="$1"; shift
    "$@" >/dev/null 2>&1
    local rc=$?
    check "$description" test "$rc" != 0
}
check 'dimensions parses binary P6 with a header comment' bash -c "tclsh '$REPO_ROOT/scripts/ppm_check.tcl' dimensions '$TEST_DIR/solid.ppm' | grep -Fxq '3x2'"
check 'a mostly-coloured region passes' "${PPM[@]}" region "$TEST_DIR/solid.ppm" 0 0 2 1 ff0000 75
check_fails 'an insufficient colour fraction fails' "${PPM[@]}" region "$TEST_DIR/solid.ppm" 0 0 3 2 ff0000 75
check 'identical files differ by zero percent' bash -c "tclsh '$REPO_ROOT/scripts/ppm_check.tcl' differs '$TEST_DIR/solid.ppm' '$TEST_DIR/solid.ppm' 0 | grep -Fq '0.000%'"
check 'a one-pixel difference is measured as 16.67 percent' bash -c "tclsh '$REPO_ROOT/scripts/ppm_check.tcl' differs '$TEST_DIR/solid.ppm' '$TEST_DIR/changed.ppm' 16.67 | grep -Fq '16.667%'"
check_fails 'a difference just beyond the threshold fails' "${PPM[@]}" differs "$TEST_DIR/solid.ppm" "$TEST_DIR/changed.ppm" 16.66
check_fails 'a truncated image is rejected' bash -c "head -c 30 '$TEST_DIR/solid.ppm' > '$TEST_DIR/truncated.ppm'; tclsh '${PPM[1]}' dimensions '$TEST_DIR/truncated.ppm'"
check_fails 'an invalid region is rejected' "${PPM[@]}" region "$TEST_DIR/solid.ppm" 0 0 4 2 ff0000 0
exit "$failures"
