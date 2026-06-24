#!/usr/bin/env bash
# scripts/test-fetch-artifacts.sh
#
# Mock-gh regression harness for the ART-04 error matrix in
# scripts/fetch-artifacts.sh.
#
# The harness writes a temporary `gh` executable into a temp directory,
# prepends that directory to PATH, and runs scripts/fetch-artifacts.sh under
# four controlled MOCK_GH_SCENARIO values:
#
#   no-release    -> gh release list returns []; script exits 0 with the D-04
#                    no-release fallback log.
#   missing-asset -> gh release list returns a tag; gh release download fails
#                    with "no assets match the file pattern"; script exits 0
#                    with a per-asset warning that names the missing asset
#                    (D-10).
#   forbidden     -> gh release list returns a tag; gh release download fails;
#                    gh api -i returns HTTP 403; script exits nonzero with an
#                    auth/rate-limit failure log (D-16, no retry).
#   server-error  -> gh release list returns a tag; gh release download fails;
#                    gh api -i returns HTTP 503; script retries a bounded
#                    number of times then exits nonzero (ART-04 5xx branch).
#
# The harness isolates each scenario in a fresh temp working directory with
# stub frozen artifacts so the real docs/ tree is never touched, cleans up on
# exit (T-04-12 mitigate: temp-dir PATH injection lives only for the duration
# of the test process), and prints `fetch-artifacts ART-04 tests: PASS` when
# all four scenarios behave as expected.
#
# No test framework is installed — this repo uses shell/build verification for
# this phase. Run with: `bash scripts/test-fetch-artifacts.sh`.

set -uo pipefail

# ----------------------------------------------------------------------------
# Locate the script under test (env-overridable for the harness).
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_ARTIFACTS_SCRIPT="${FETCH_ARTIFACTS_SCRIPT:-$SCRIPT_DIR/fetch-artifacts.sh}"

if [[ ! -f "$FETCH_ARTIFACTS_SCRIPT" ]]; then
  echo "ERROR: FETCH_ARTIFACTS_SCRIPT not found at $FETCH_ARTIFACTS_SCRIPT" >&2
  exit 99
fi

# ----------------------------------------------------------------------------
# Temp workspace — cleaned up on exit (T-04-12 mitigate: temp-dir PATH
# injection lives only for the duration of the test process).
# ----------------------------------------------------------------------------
WORK_ROOT="$(mktemp -d)"
BIN_DIR="$WORK_ROOT/bin"
mkdir -p "$BIN_DIR"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# mock gh — emulates `gh release list`, `gh release download`, and `gh api -i`
# based on MOCK_GH_SCENARIO. The mock is written into BIN_DIR and prepended to
# PATH for each scenario run so scripts/fetch-artifacts.sh resolves `gh` here
# instead of the real GitHub CLI. The mock never touches the network.
# ----------------------------------------------------------------------------
write_mock_gh() {
  local target="$1"
  cat > "$target" <<'MOCK_GH'
#!/usr/bin/env bash
# mock gh for ART-04 regression tests — not the real GitHub CLI.
set -uo pipefail
scenario="${MOCK_GH_SCENARIO:-no-release}"

# gh release list -R <repo> --json tagName -L 100 --jq <filter>
# Emulate the jq-filtered tagName output (empty for no-release so resolve_tag
# returns "" and the script takes the D-04 frozen-fallback path).
if [[ "${1:-}" == "release" && "${2:-}" == "list" ]]; then
  case "$scenario" in
    no-release)
      # No output -> resolve_tag captures "" -> D-04 no-release fallback.
      exit 0
      ;;
    missing-asset|forbidden|server-error)
      printf 'v1.13.4\n'
      exit 0
      ;;
    *)
      echo "mock gh: unknown scenario $scenario for release list" >&2
      exit 1
      ;;
  esac
fi

# gh release download <tag> -R <repo> -p <asset> -D <dir> --clobber
# Emulate failure stderr for each ART-04 branch. The exit code is always 1
# (gh's generic failure code); classify_fetch_failure inspects the stderr
# string first, then falls back to `gh api -i` for the HTTP status (Pitfall 2).
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  case "$scenario" in
    missing-asset)
      echo "no assets match the file pattern" >&2
      exit 1
      ;;
    forbidden)
      echo "HTTP 403 Forbidden (mock)" >&2
      exit 1
      ;;
    server-error)
      echo "HTTP 503 Service Unavailable (mock)" >&2
      exit 1
      ;;
    *)
      echo "mock gh: unexpected release download in scenario $scenario" >&2
      exit 1
      ;;
  esac
fi

# gh api <path> -i -> print HTTP status line + headers. classify_fetch_failure
# greps the 3-digit status from the first line to classify 403/429 vs 5xx.
if [[ "${1:-}" == "api" ]]; then
  case "$scenario" in
    forbidden)
      printf 'HTTP/2.0 403\ncontent-type: application/json\n\n'
      exit 0
      ;;
    server-error)
      printf 'HTTP/2.0 503\ncontent-type: application/json\n\n'
      exit 0
      ;;
    *)
      printf 'HTTP/2.0 404\ncontent-type: application/json\n\n'
      exit 0
      ;;
  esac
fi

echo "mock gh: unhandled command: $*" >&2
exit 1
MOCK_GH
  chmod +x "$target"
}

write_mock_gh "$BIN_DIR/gh"

# ----------------------------------------------------------------------------
# make_work_dir — stub frozen artifacts in a per-scenario working directory so
# the real docs/ tree is never touched. stage_openapi_viewer copies from
# docs/.openapi/ and update_python_landing reads docs/api/python.md; both
# resolve relative to the scenario cwd, so the stubs keep those functions
# working without touching the real committed files.
# ----------------------------------------------------------------------------
make_work_dir() {
  local d
  d="$(mktemp -d -p "$WORK_ROOT")"
  mkdir -p "$d/docs/.openapi" "$d/docs/api"
  printf '<html><!-- stub swagger-ui -->\n' > "$d/docs/.openapi/swagger-ui.html"
  printf '/* stub custom css */\n'              > "$d/docs/.openapi/custom.css"
  printf 'openapi: 3.0.0 stub\n'               > "$d/docs/.openapi/api.yaml"
  printf '# stub rest markdown\n'              > "$d/docs/api/rest.md"
  printf '# Python API\n\n## Sphinx API reference\n\n> Sphinx UI not yet available.\n\n## Installation\n\n```\npip install dbrepo\n```\n' > "$d/docs/api/python.md"
  printf '%s\n' "$d"
}

# ----------------------------------------------------------------------------
# run_scenario — execute scripts/fetch-artifacts.sh under a MOCK_GH_SCENARIO in
# an isolated subshell. Captures exit code, stdout, stderr into global slots
# for the assertion helpers. The subshell isolates PATH and cwd changes so the
# parent harness environment is never polluted.
# ----------------------------------------------------------------------------
SCENARIO=""      # name of the scenario currently running
RUN_RC=0         # exit code of the last run
RUN_OUT=""       # path to captured stdout
RUN_ERR=""       # path to captured stderr
RUN_COMBINED=""  # path to combined stdout+stderr

run_scenario() {
  local scenario="$1"
  SCENARIO="$scenario"
  local wd
  wd="$(make_work_dir)"
  RUN_OUT="$wd/out.log"
  RUN_ERR="$wd/err.log"
  RUN_COMBINED="$wd/combined.log"
  (
    cd "$wd" || exit 99
    export PATH="$BIN_DIR:$PATH"
    export MOCK_GH_SCENARIO="$scenario"
    export RELEASE_REPO="owner/repo"
    export DOC_VERSION="1.13"
    export FETCH_RETRY_SLEEP=0
    export PYTHON_ARCHIVE="$wd/python-sphinx.tar.gz"
    bash "$FETCH_ARTIFACTS_SCRIPT" >"$RUN_OUT" 2>"$RUN_ERR"
  )
  RUN_RC=$?
  cat "$RUN_OUT" "$RUN_ERR" 2>/dev/null > "$RUN_COMBINED" || true
}

# ----------------------------------------------------------------------------
# Assertion helpers. Each prints PASS/FAIL and increments FAIL_COUNT on
# failure. Combined output (stdout+stderr) is checked because
# scripts/fetch-artifacts.sh logs to both streams.
# ----------------------------------------------------------------------------
FAIL_COUNT=0
PASS_COUNT=0

dump_logs() {
  echo "        --- stdout ---" >&2
  sed 's/^/        | /' "$RUN_OUT" >&2 2>/dev/null || true
  echo "        --- stderr ---" >&2
  sed 's/^/        | /' "$RUN_ERR" >&2 2>/dev/null || true
}

assert_exit() {
  local expected="$1" label="$2"
  if [[ "$RUN_RC" -eq "$expected" ]]; then
    echo "  [PASS] $SCENARIO: $label (exit $RUN_RC)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $SCENARIO: $label (expected exit $expected, got $RUN_RC)" >&2
    dump_logs
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_nonzero_exit() {
  local label="$1"
  if [[ "$RUN_RC" -ne 0 ]]; then
    echo "  [PASS] $SCENARIO: $label (exit $RUN_RC)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $SCENARIO: $label (expected nonzero exit, got 0)" >&2
    dump_logs
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_log() {
  local pattern="$1" label="$2"
  if grep -qiE -- "$pattern" "$RUN_COMBINED" 2>/dev/null; then
    echo "  [PASS] $SCENARIO: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $SCENARIO: $label (pattern '$pattern' not found)" >&2
    dump_logs
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ----------------------------------------------------------------------------
# Scenarios.
# ----------------------------------------------------------------------------
echo "fetch-artifacts ART-04 regression harness"
echo "script under test: $FETCH_ARTIFACTS_SCRIPT"
echo

# --- no-release (D-04) ------------------------------------------------------
run_scenario "no-release"
assert_exit 0 "no-release exits 0"
# D-04 log line names the docs version and repo with the em-dash contract.
assert_log "No release matching v1\.13" "no-release logs D-04 fallback line"
echo

# --- missing-asset (D-10) ---------------------------------------------------
run_scenario "missing-asset"
assert_exit 0 "missing-asset exits 0 (per-asset fallback)"
# classify_fetch_failure warns and names the missing asset on one log line
# (the unhardened script's generic WARNING does not contain "missing", so this
# is a precise RED/GREEN discriminator).
assert_log "openapi\.yaml.*missing from release" "missing-asset warns and names the missing asset"
echo

# --- forbidden (D-16, no retry) --------------------------------------------
run_scenario "forbidden"
assert_nonzero_exit "forbidden exits nonzero (fail job, no retry)"
# classify_fetch_failure logs the literal AUTH/RATE-LIMIT failure marker; the
# mock's "HTTP 403" stderr does not contain it, so this is a precise
# RED/GREEN discriminator (the hardened script also redirects gh stderr to a
# file, so the mock line never reaches the combined log in GREEN).
assert_log "AUTH/RATE-LIMIT" "forbidden logs auth/rate-limit failure"
echo

# --- server-error (ART-04 5xx retry then fail) -----------------------------
run_scenario "server-error"
assert_nonzero_exit "server-error exits nonzero after retry exhaustion"
# with_retries logs retry attempts before final failure.
assert_log "retry|attempt|transient" "server-error retries before failing"
echo

# ----------------------------------------------------------------------------
# Result.
# ----------------------------------------------------------------------------
echo "----------------------------------------"
echo "  PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
echo "----------------------------------------"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "fetch-artifacts ART-04 tests: PASS"
  exit 0
else
  echo "fetch-artifacts ART-04 tests: FAIL ($FAIL_COUNT assertion(s) failed)" >&2
  exit 1
fi
