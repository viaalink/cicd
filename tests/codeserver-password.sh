#!/bin/bash
# VS Code's own password (the codeserver-password input) against a stub `via`:
# empty, VS Code asks for the login password again; given, VS Code gets that
# one and the login in front keeps its own; the value is checked like the
# login password, masked, and never printed; the run summary says which
# password VS Code asks for.
#
# Run: bash tests/codeserver-password.sh   (needs bash, jq; no network, no real CLI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAILS=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

export LOGIN_PROBE_INTERVAL=0 LOGIN_PROBE_TRIES=3
LOGIN='l o$g"in'
OWN='ed`it$or "pw'

make_stubs() {
  local t="$1"
  mkdir -p "$t/bin" "$t/fake"
  # via: `codeserver start` keeps the password it was given as step env, the
  # way the CLI reads it; expose publishes one address with its auth word.
  cat > "$t/bin/via" <<'STUB'
#!/bin/bash
echo "via $*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  "init --yes")
    cp .env .env.bak; chmod 600 .env.bak
    echo "ASD_CODESERVER_PORT=18443" >> .env
    mkdir -p "${VIA_WORKSPACE_DIR:-workspace}" .via ;;
  "codeserver start") printf '%s' "${VIA_CODESERVER_PASSWORD:-}" > "$FAKE/codeserver-env-password"; touch "$FAKE/caddy" ;;
  "codeserver stop")  rm -f "$FAKE/codeserver-env-password" ;;
  "caddy stop")       rm -f "$FAKE/caddy" ;;
  "expose stop")      rm -f "$FAKE/exposed" ;;
  "expose list")
    if [ -f "$FAKE/exposed" ]; then
      echo '{"exposed":[{"id":"demo","name":"demo","url":"https://demo-ci.relay.example.com/","alive":true,"state":"online"}]}'
    else echo '{"exposed":[]}'; fi ;;
  "expose "[0-9]*) echo "$4" > "$FAKE/auth-demo"; touch "$FAKE/exposed" "$FAKE/caddy" ;;
esac
exit 0
STUB
  cat > "$t/bin/pgrep" <<'STUB'
#!/bin/bash
[ "$*" = "-x caddy" ] && [ -f "$FAKE/caddy" ]
STUB
  # curl: 401 with a Basic challenge without credentials while exposed, 404 after.
  cat > "$t/bin/curl" <<'STUB'
#!/bin/bash
hdrfile=""; prev=""; creds=0
for a in "$@"; do [ "$prev" = "-D" ] && hdrfile="$a"; [ "$a" = "-u" ] && creds=1; prev="$a"; done
emit() {
  if [ -n "$hdrfile" ]; then
    { printf 'HTTP/2 %s\r\n' "$1"; [ "${2:-}" = basic ] && printf 'www-authenticate: Basic realm="restricted"\r\n'; printf '\r\n'; } > "$hdrfile"
  fi
  printf '%s' "$1"
}
if [ -f "$FAKE/exposed" ]; then
  if [ "$creds" = 0 ]; then emit 401 basic; else emit 200; fi
else emit 404; fi
STUB
  chmod +x "$t/bin/"*
}

# credentials.sh with a VS Code session (overrides as KEY=VALUE arguments).
cred() {
  env INPUT_TUNNEL_KEY=k INPUT_TUNNEL_KEY_ID=i INPUT_TUNNEL_HOST=h INPUT_HOST_KEY_FINGERPRINTS=SHA256:x \
    INPUT_PASSWORD="$LOGIN" INPUT_USERNAME=via INPUT_INTERFACE=codeserver INPUT_MODE=interactive \
    INPUT_CLI_VERSION=latest GITHUB_SHA=abcdef1234 INPUT_TIMEOUT_MINUTES=0 INPUT_EXPOSE="" \
    RUNNER_TEMP="$(mktemp -d)" GITHUB_WORKSPACE="$(mktemp -d)" GITHUB_ACTIONS="" GITLAB_CI="" SCRIPTS_DIR="$SCRIPTS" \
    "$@" bash "$SCRIPTS/credentials.sh" 2>&1
}
accepted() { cred "$@" >/dev/null; }
refused() { ! cred "$@" >/dev/null; }

# start-interface.sh + connect.sh in a checkout; $2 = the codeserver-password input.
start_vscode() {
  local t="$1" own="$2"
  mkdir -p "$t/repo" "$t/state"
  printf 'MINE=1\n' > "$t/repo/.env"
  printf '.env\n' > "$t/repo/.gitignore"
  git -C "$t/repo" init -q
  git -C "$t/repo" add .gitignore
  git -C "$t/repo" -c user.name=t -c user.email=t@t commit -qm init
  : > "$t/state/expose-spec"
  # As action.yml passes them: the input itself, and the CLI's env with the fallback.
  (cd "$t/repo" && env FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=demo SESSION_INTERFACE=codeserver \
    VIA_WORKSPACE_DIR="$t/repo/workspace" SESSION_USERNAME=via SESSION_PASSWORD="$LOGIN" SESSION_SHELL=bash \
    SESSION_CODESERVER_PASSWORD="$own" VIA_CODESERVER_AUTH=password VIA_CODESERVER_PASSWORD="${own:-$LOGIN}" \
    VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD="$LOGIN" SCRIPTS_DIR="$SCRIPTS" \
    PATH="$t/bin:$PATH" GITHUB_ACTIONS="" GITLAB_CI="" CI_RUNNER_OS=Linux \
    bash "$SCRIPTS/start-interface.sh" >"$t/start.log" 2>&1)
  cp "$t/repo/.env" "$t/env-while-running"
  (cd "$t/repo" && env FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=demo SESSION_INTERFACE=codeserver \
    SESSION_TARGET=18443 SESSION_TIMEOUT_MINUTES=0 SESSION_MODE=interactive \
    SESSION_CODESERVER_OWN_PASSWORD="$([ -n "$own" ] && echo true || echo false)" \
    VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD="$LOGIN" SCRIPTS_DIR="$SCRIPTS" \
    PATH="$t/bin:$PATH" GITHUB_ACTIONS=true GITHUB_OUTPUT="$t/out" GITHUB_STEP_SUMMARY="$t/summary" \
    GITHUB_TOKEN="" GITHUB_REPOSITORY="" GITLAB_CI="" CI_RUNNER_OS=Linux \
    bash "$SCRIPTS/connect.sh" >"$t/connect.log" 2>&1)
}

# The value of KEY in a .env file, as bash reads it back.
env_value() { ( set +u; # shellcheck disable=SC1090
  source "$1"; printf '%s' "${!2}" ); }

echo "# 1. The input is checked like the login password"
check "empty is accepted (the default)" accepted INPUT_CODESERVER_PASSWORD=
check "a value is accepted" accepted INPUT_CODESERVER_PASSWORD="$OWN"
check "a line break is refused" refused INPUT_CODESERVER_PASSWORD=$'one\ntwo'
check "only whitespace is refused" refused INPUT_CODESERVER_PASSWORD='   '
check "accepted with another interface too (one workflow, the interface as an input)" \
  accepted INPUT_CODESERVER_PASSWORD="$OWN" INPUT_INTERFACE=terminal
ERR="$(cred INPUT_CODESERVER_PASSWORD=$'se\ncret' || true)"
check "the error names the input, not its value" bash -c 'grep -q "codeserver-password" <<<"$1" && ! grep -q "se$" <<<"$1"' _ "$ERR"
MASKS="$(cred INPUT_CODESERVER_PASSWORD="$OWN" GITHUB_ACTIONS=true GITHUB_OUTPUT=/dev/null)"
check "the value is masked" grep -qxF "::add-mask::${OWN}" <<<"$MASKS"
check "nothing is masked for an empty input" bash -c '! grep -qx "::add-mask::" <<<"$1"' _ "$(cred INPUT_CODESERVER_PASSWORD= GITHUB_ACTIONS=true GITHUB_OUTPUT=/dev/null)"

echo "# 2. Empty: VS Code asks for the login password again"
T2="$(mktemp -d)"; make_stubs "$T2"; start_vscode "$T2" ""
check "VS Code's password in .env is the login password" test "$(env_value "$T2/env-while-running" ASD_CODESERVER_PASSWORD)" = "$LOGIN"
check "VS Code has its own login switched on" grep -qx "ASD_CODESERVER_AUTH=password" "$T2/env-while-running"
check "the CLI got the login password as VS Code's" test "$(cat "$T2/fake/codeserver-env-password")" = "$LOGIN"
check "the summary says the login password again" grep -q "asks for a password of its own: the login password again" "$T2/summary"

echo "# 3. Given: VS Code gets its own, the login in front keeps the login password"
T3="$(mktemp -d)"; make_stubs "$T3"; start_vscode "$T3" "$OWN"
check "VS Code's password in .env is the given one" test "$(env_value "$T3/env-while-running" ASD_CODESERVER_PASSWORD)" = "$OWN"
check "the login in front is still the login password" test "$(env_value "$T3/env-while-running" ASD_BASIC_AUTH_PASSWORD)" = "$LOGIN"
check "the CLI got the given one as VS Code's" test "$(cat "$T3/fake/codeserver-env-password")" = "$OWN"
check "the address is published behind the login" test "$(cat "$T3/fake/auth-demo")" = "--auth=basic"
check "the summary names the input" grep -qF 'the one passed as `codeserver-password`' "$T3/summary"
check "neither password is in a log or the summary" bash -c '! grep -qF -e "$1" -e "$2" "$3/start.log" "$3/connect.log" "$3/summary"' _ "$OWN" "$LOGIN" "$T3"
URL_OUT="$(grep '^url=' "$T3/out" | cut -d= -f2-)"
check "the url output carries the login password, not VS Code's" bash -c '[[ "$1" == https://via:*@demo-ci.relay.example.com/ ]] && [[ "$1" != *ed%60it* ]]' _ "$URL_OUT"

echo "# 4. action.yml passes the input as step env only"
check "the input is declared" grep -q '^  codeserver-password:' "$ROOT/action.yml"
check "VS Code's env falls back to the login password" \
  grep -qF 'VIA_CODESERVER_PASSWORD: ${{ inputs.codeserver-password || inputs.password || steps.credentials.outputs.generated_password }}' "$ROOT/action.yml"
check "never in a run: line" bash -c '! grep -E "^\s*run:.*codeserver-password" "$1"' _ "$ROOT/action.yml"

rm -rf "$T2" "$T3"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
