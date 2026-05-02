#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1091
source ./schedule-network-task

verbose=0
case "${1:-}" in
  -v|--verbose) verbose=1; shift ;;
esac

say() { (( verbose )) && printf '%s\n' "$*"; return 0; }

fail=0
assert_eq() {
  local expected=$1 actual=$2 desc=$3
  if [[ $expected == "$actual" ]]; then
    say "  ok: $desc"
  else
    printf "  FAIL: %s — expected %q, got %q\n" "$desc" "$expected" "$actual"
    fail=1
  fi
}

# Run a command expected to fail with non-zero exit, optionally checking that
# stderr contains a substring. Used for input-validation tests.
assert_rejects() {
  local desc=$1 needle=$2; shift 2
  local err
  if err=$("$@" 2>&1 >/dev/null); then
    printf "  FAIL: %s — expected non-zero exit, got success\n" "$desc"
    fail=1
    return
  fi
  if [[ -n $needle && $err != *"$needle"* ]]; then
    printf "  FAIL: %s — stderr missing %q; got %q\n" "$desc" "$needle" "$err"
    fail=1
    return
  fi
  say "  ok: $desc"
}

assert_contains() {
  local needle=$1 haystack=$2 desc=$3
  if [[ $haystack == *"$needle"* ]]; then
    say "  ok: $desc"
  else
    printf "  FAIL: %s — output missing %q\n" "$desc" "$needle"
    fail=1
  fi
}

say "parse_duration:"
assert_eq 60      "$(parse_duration 60)"          "plain seconds: 60 → 60"
assert_eq 0       "$(parse_duration 0)"           "plain zero → 0 (caller rejects)"
assert_eq 45      "$(parse_duration 45s)"         "45s"
assert_eq 60      "$(parse_duration 1m)"          "1m"
assert_eq 3600    "$(parse_duration 1h)"          "1h"
assert_eq 86400   "$(parse_duration 1d)"          "1d"
assert_eq 5400    "$(parse_duration 90m)"         "90m (single unit > 60)"
assert_eq 93784   "$(parse_duration 1d2h3m4s)"    "compound 1d2h3m4s"
assert_eq 16200   "$(parse_duration 4h30m)"       "4h30m"
assert_eq 469830  "$(parse_duration 5d10h30m30s)" "5d10h30m30s"
assert_eq 93784   "$(parse_duration 1D2H3M4S)"    "uppercase units"
assert_eq 0       "$(parse_duration "")"          "empty → 0"
assert_eq 0       "$(parse_duration 0s)"          "all-zero pieces → 0 (caller rejects)"
assert_eq 0       "$(parse_duration xyz)"         "garbage → 0"
assert_eq 0       "$(parse_duration 1xyz)"        "trailing garbage → 0"
assert_eq 0       "$(parse_duration 30m1h)"       "out of order → 0"

say
say "human_duration:"
assert_eq ""         "$(human_duration 0)"     "0 → empty"
assert_eq "1s"       "$(human_duration 1)"     "1 → 1s"
assert_eq "1m"       "$(human_duration 60)"    "60 → 1m"
assert_eq "1h"       "$(human_duration 3600)"  "3600 → 1h"
assert_eq "1d"       "$(human_duration 86400)" "86400 → 1d"
assert_eq "1d2h3m4s" "$(human_duration 93784)" "93784 → 1d2h3m4s"
assert_eq "4h30m"    "$(human_duration 16200)" "16200 → 4h30m"
assert_eq "1m30s"    "$(human_duration 90)"    "90 → 1m30s (skip h, d)"
assert_eq "1h1m1s"   "$(human_duration 3661)"  "3661 → 1h1m1s (skip d)"

say
say "schedule-network-task input validation:"
assert_rejects "no args (Usage)"         "Usage:"             ./schedule-network-task
assert_rejects "duration only"           "missing command"    ./schedule-network-task 1s
assert_rejects "unknown flag"            "unknown flag"       ./schedule-network-task --bogus 1s echo x
assert_rejects "--gate without value"    "requires"           ./schedule-network-task --gate
assert_rejects "--gate followed by flag" "requires"           ./schedule-network-task --gate --bogus 1s echo x
assert_rejects "empty host"              "invalid host:port"  ./schedule-network-task --gate ":443" 1s echo x
assert_rejects "empty port"              "invalid host:port"  ./schedule-network-task --gate "x:"   1s echo x
assert_rejects "non-numeric port"        "invalid host:port"  ./schedule-network-task --gate "x:ab" 1s echo x
assert_rejects "port 0 out of range"     "invalid host:port"  ./schedule-network-task --gate "x:0"  1s echo x
assert_rejects "port too large"          "invalid host:port"  ./schedule-network-task --gate "x:65536" 1s echo x
assert_rejects "no colon in --gate"      "invalid host:port"  ./schedule-network-task --gate "xyz"  1s echo x
assert_rejects "command not found"       "command not found"  ./schedule-network-task 1s nonexistent_cmd_xyz
assert_rejects "invalid duration"        "invalid duration"   ./schedule-network-task --gate x:443 xyz echo x

say
say "schedule-network-task default gate (1.1.1.1:443) when host:port omitted:"
stub_dir=$(mktemp -d)
nc_log=$(mktemp)
cat > "$stub_dir/nc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$NC_LOG"
exit 0
EOF
chmod +x "$stub_dir/nc"

# `|| true` so a non-zero exit (or set -e tripping inside) doesn't skip
# cleanup below — the assertions surface any actual failure.
out=$(NC_LOG=$nc_log PATH="$stub_dir:$PATH" ./schedule-network-task 1s echo gated 2>&1) || true

assert_contains "gating on 1.1.1.1:443" "$out"             "default gate appears in diagnostic"
assert_contains "gated"                  "$out"             "command exec'd after gate"
assert_contains "1.1.1.1 443"            "$(cat "$nc_log")" "nc called with default target"

rm -rf "$stub_dir" "$nc_log"

say
say "wait_for_network: survives unreachable target (regression: unbraced var before … tripped set -u):"
out=$(
  ./schedule-network-task --gate 127.0.0.1:1 1s echo x 2>&1 &
  pid=$!
  sleep 2
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null
  true
)
if [[ $out == *"unbound variable"* ]]; then
  printf "  FAIL: crashed with unbound variable\n  output: %s\n" "$out"
  fail=1
elif [[ $out == *"Waiting for network"* ]]; then
  say "  ok: entered retry loop"
else
  printf "  FAIL: never reached retry loop\n  output: %s\n" "$out"
  fail=1
fi

say
if (( fail )); then
  echo "FAILED"
  exit 1
fi
echo "PASS"
