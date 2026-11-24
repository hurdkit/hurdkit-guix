#!/usr/bin/env bash
# TAP: the jobs that restore goonix from the Actions cache go on without it.
# The goonix job (.github/workflows/goonix.yml) only looks goonix up, and
# GitHub can evict the entry before the jobs after it restore it. A job
# that failed on that miss would fail every check of the run, so each
# restore of the goonix key must not fail on a miss, must be followed by a
# warning on a miss, and then by the development shell, which builds goonix
# when it is missing.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

number=0
failures=0
ok() { number=$((number + 1)); echo "ok $number - $*"; }
not_ok() {
    number=$((number + 1))
    echo "not ok $number - $1"
    [[ -z "${2:-}" ]] || while IFS= read -r line; do echo "# $line"; done <<<"$2"
    failures=$((failures + 1))
}

# goonix_restores FILE: one line per step of FILE that restores the goonix
# key: "LINE ok" when the step and the two after it are as above, else
# "LINE" and what is wrong.
goonix_restores() {
    awk '
        function flush() { if (cur != "") { n++; block[n] = cur; first[n] = from }; cur = "" }
        {
            match($0, /^ */); indent = RLENGTH
            if ($0 ~ /^      - /) { flush(); from = NR; cur = $0 "\n"; next }
            if ($0 !~ /^[[:space:]]*(#.*)?$/ && indent < 6) { flush(); next }
            if (cur != "") cur = cur $0 "\n"
        }
        END {
            flush()
            for (i = 1; i <= n; i++) {
                if (block[i] !~ /actions\/cache\/restore@/ ||
                    block[i] !~ /key: \$\{\{ needs\.goonix\.outputs\.key \}\}/) continue
                wrong = ""
                if (block[i] ~ /fail-on-cache-miss: *true/) wrong = wrong " fails-on-a-miss"
                id = ""
                if (match(block[i], /\n *id: *[A-Za-z0-9_-]+/)) {
                    id = substr(block[i], RSTART, RLENGTH); sub(/.*id: */, "", id)
                }
                if (id == "") wrong = wrong " no-id"
                warn = block[i + 1]
                if (id == "" || index(warn, "if: steps." id ".outputs.cache-hit != '\''true'\''") == 0 ||
                    warn !~ /::warning::/) wrong = wrong " no-warning-on-a-miss"
                if (block[i + 2] !~ /nix develop/) wrong = wrong " no-development-shell-after-it"
                print first[i], (wrong == "" ? "ok" : substr(wrong, 2))
            }
        }' "$1"
}

# --- The check itself, on workflows written here ---
cat > "$TEST_DIR/good.yml" <<'YAML'
jobs:
  a:
    steps:
      - name: Restore goonix
        id: goonix-cache
        uses: actions/cache/restore@0000000000000000000000000000000000000000
        with:
          path: ~/.cache/hurdkit-ci/nix
          key: ${{ needs.goonix.outputs.key }}
      - name: Goonix not in the cache
        if: steps.goonix-cache.outputs.cache-hit != 'true'
        run: echo "::warning::goonix was not in the Actions cache"
      - name: Development shell (G1)
        run: nix develop --command guix --version
YAML
result="$(goonix_restores "$TEST_DIR/good.yml")"
if [[ "$result" == "4 ok" ]]; then
    ok 'a restore that goes on without goonix passes'
else
    not_ok 'a restore that goes on without goonix passes' "$result"
fi
sed 's|^          key: .*|&\n          fail-on-cache-miss: true|' "$TEST_DIR/good.yml" > "$TEST_DIR/fails.yml"
result="$(goonix_restores "$TEST_DIR/fails.yml")"
if [[ "$result" == *fails-on-a-miss* ]]; then
    ok 'a restore that fails on a miss is reported'
else
    not_ok 'a restore that fails on a miss is reported' "$result"
fi
sed '/^      - name: Goonix not in the cache/,/^        run: echo/d' "$TEST_DIR/good.yml" > "$TEST_DIR/silent.yml"
result="$(goonix_restores "$TEST_DIR/silent.yml")"
if [[ "$result" == *no-warning-on-a-miss* ]]; then
    ok 'a restore without the warning after it is reported'
else
    not_ok 'a restore without the warning after it is reported' "$result"
fi

# --- The workflows that restore goonix ---
for workflow in guests images; do
    file="$REPO_ROOT/.github/workflows/$workflow.yml"
    result="$(goonix_restores "$file")"
    if [[ -z "$result" ]]; then
        not_ok "$workflow.yml restores goonix" 'no step restores the goonix key'
    elif grep -qv ' ok$' <<<"$result"; then
        not_ok "every goonix restore of $workflow.yml goes on without goonix" \
            "$(grep -v ' ok$' <<<"$result" | sed "s|^|$workflow.yml line |")"
    else
        ok "every goonix restore of $workflow.yml goes on without goonix"
    fi
done

echo "1..$number"
(( failures == 0 ))
