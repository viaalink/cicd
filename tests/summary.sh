#!/bin/bash
# The run summary is the action's to write, against a stub `via` that does what
# the CLI does in a GitHub job: append a block of its own ("Open the hub ...")
# to GITHUB_STEP_SUMMARY when it publishes. The action keeps that block out,
# and says where the address is when GitHub shows it as *** (the relay's host
# name is a secret): the View deployment button when there is one.
#
# Run: bash tests/summary.sh   (needs bash, jq; no network, no real CLI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAILS=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

export LOGIN_PROBE_INTERVAL=0 LOGIN_PROBE_TRIES=3

make_stubs() {
  local t="$1"
  mkdir -p "$t/bin" "$t/fake/exposed.d" "$t/state" "$t/project"
  cat > "$t/bin/via" <<'STUB'
#!/bin/bash
echo "via $*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  "expose stop") rm -f "$FAKE/exposed.d/$3" ;;
  "caddy stop")  rm -f "$FAKE/caddy" ;;
  "expose list")
    rows=""
    for f in "$FAKE"/exposed.d/*; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      rows="${rows:+$rows,}$(jq -cn --arg n "$n" --arg u "https://$n-ci.relay.example.com/" \
        '{id: $n, name: $n, url: $u, alive: true, state: "online", appUp: true}')"
    done
    echo "{\"exposed\":[${rows}]}" ;;
  "expose "*)
    # The CLI's own block, as modules/publish writes it in a GitHub job.
    if [ "${CI:-}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf '### Viaalink CI/CD\n[Open the hub](https://%s-ci.relay.example.com)\n\n> **Please note:** After starting this workflow, it can take **1-2 minutes** before the next flow is fully running.\n' "$3" >> "$GITHUB_STEP_SUMMARY"
    fi
    touch "$FAKE/exposed.d/$3" "$FAKE/caddy" ;;
esac
exit 0
STUB
  cat > "$t/bin/pgrep" <<'STUB'
#!/bin/bash
[ "$*" = "-x caddy" ] && [ -f "$FAKE/caddy" ]
STUB
  # curl: the GitHub deployments API (an id when FAKE/deployments exists, else
  # refused, as without deployments: write), and the published address: 401
  # with a Basic challenge without credentials, 200 with.
  cat > "$t/bin/curl" <<'STUB'
#!/bin/bash
hdrfile=""; prev=""; creds=0; url=""
for a in "$@"; do
  [ "$prev" = "-D" ] && hdrfile="$a"
  [ "$a" = "-u" ] && creds=1
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  https://api.github.com/*/deployments)
    [ -f "$FAKE/deployments" ] || exit 22
    echo "$*" > "$FAKE/deployment-call"; echo '{"id": 4242}'; exit 0 ;;
  https://api.github.com/*/statuses) echo "$*" > "$FAKE/deployment-status-call"; exit 0 ;;
esac
code=200; [ "$creds" = 0 ] && code=401
if [ -n "$hdrfile" ]; then
  { printf 'HTTP/2 %s\r\n' "$code"; [ "$code" = 401 ] && printf 'www-authenticate: Basic realm="restricted"\r\n'; printf '\r\n'; } > "$hdrfile"
fi
printf '%s' "$code"
STUB
  chmod +x "$t/bin/"*
}

# connect.sh for a terminal session, as a GitHub job runs it.
connect() {
  local t="$1"
  : > "$t/out"; : > "$t/summary"
  (cd "$t/project" && env FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=review SESSION_INTERFACE=terminal \
    SESSION_TARGET=ttyd SESSION_TIMEOUT_MINUTES=0 SESSION_MODE=interactive SESSION_CODESERVER_OWN_PASSWORD=false \
    VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD='p w' SCRIPTS_DIR="$SCRIPTS" PATH="$t/bin:$PATH" \
    CI=true GITHUB_ACTIONS=true GITHUB_OUTPUT="$t/out" GITHUB_STEP_SUMMARY="$t/summary" \
    GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r GITHUB_SHA=abc GITLAB_CI="" CI_RUNNER_OS=Linux \
    bash "$SCRIPTS/connect.sh" >"$t/connect.log" 2>&1)
}

echo "# 1. With a View deployment button"
T1="$(mktemp -d)"; make_stubs "$T1"; touch "$T1/fake/deployments"
check "connect.sh publishes" connect "$T1"
check "the CLI's own block is not in the summary" bash -c '! grep -q -e "Open the hub" -e "Please note" "$1"' _ "$T1/summary"
check "the summary has one heading: the action's" test "$(grep -c '^#' "$T1/summary")" = 1
check "it says Terminal ready" grep -qx '## Terminal ready' "$T1/summary"
check "it lists the address and the user name" grep -qF '**[https://review-ci.relay.example.com/](https://review-ci.relay.example.com/)** (sign in as `via`)' "$T1/summary"
check "it says why the address can show ***" grep -qF 'Does the address show `***`? GitHub hides your relay'"'"'s host name here' "$T1/summary"
check "and names the View deployment button" grep -qF 'Use the **View deployment** button on this page' "$T1/summary"
check "the deployment holds the address as it is" grep -qF 'https://review-ci.relay.example.com/' "$T1/fake/deployment-status-call"
check "the deployment id is a step output" grep -qx 'deploy_id=4242' "$T1/out"
check "the password is in no log and not in the summary" bash -c '! grep -qF "p w" "$1/connect.log" "$1/summary"' _ "$T1"

echo "# 2. Without one (no deployments: write)"
T2="$(mktemp -d)"; make_stubs "$T2"
check "connect.sh publishes" connect "$T2"
check "the summary does not point at a button that is not there" bash -c '! grep -qF "Use the **View deployment** button" "$1"' _ "$T2/summary"
check "it names the permission and the command instead" grep -qF 'Give the job `deployments: write` for a **View deployment** button with the address, or run `via gh active` on your own device.' "$T2/summary"
check "the CLI's own block is not in the summary" bash -c '! grep -q "Open the hub" "$1"' _ "$T2/summary"

echo "# 3. Exposed services"
T3="$(mktemp -d)"; make_stubs "$T3"
printf '3000\tshop\tlogin\tshop-0123456789abcdef\n' > "$T3/state/expose-spec"
echo no > "$T3/state/caddy-before"
: > "$T3/out"; : > "$T3/env"; : > "$T3/summary"
check "expose.sh publishes" bash -c 'cd "$1/project" && env FAKE="$1/fake" PATH="$1/bin:$PATH" STATE_DIR="$1/state" SESSION_NAME=review \
  SESSION_MODE=background SCRIPTS_DIR="$2" CI=true GITHUB_ACTIONS=true GITHUB_OUTPUT="$1/out" GITHUB_ENV="$1/env" \
  GITHUB_STEP_SUMMARY="$1/summary" bash "$2/expose.sh" >"$1/expose.log" 2>&1' _ "$T3" "$SCRIPTS"
check "the CLI's own block is not in the summary" bash -c '! grep -q "Open the hub" "$1"' _ "$T3/summary"
check "the table lists the service" grep -qF '| `shop` | 3000 | https://shop-0123456789abcdef-ci.relay.example.com | login |' "$T3/summary"
check "it says where the full addresses are" grep -qF 'Later steps get the full addresses from the `urls` output and `VIAALINK_URL_<NAME>`.' "$T3/summary"

rm -rf "$T1" "$T2" "$T3"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
