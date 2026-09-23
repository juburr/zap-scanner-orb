#!/bin/bash

# Exercises src/scripts/scan.sh directly, covering parameter validation, plan
# generation, argument passing, and result handling. Most tests use a fake
# zap.sh so they run in milliseconds; the rest run real scans.
#
# Optional environment:
#   SCAN_TARGET  URL of a running web server whose pages raise medium risk
#                alerts, such as a stock nginx. Real scans are skipped without
#                it, and also need Java and a real zap.sh (2.16.0+) on the PATH.

# Single-quoted snippets below are expanded by child shells, not this one.
# shellcheck disable=SC2016

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${REPO_ROOT}/src/scripts/scan.sh"
FIXTURES="${REPO_ROOT}/.circleci/zap"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
# Anything a regression writes to the working directory is cleaned up too.
cd "${WORK}" || exit 1

PASSED=0
FAILED=0
FAILED_NAMES=()
CURRENT=""
CURRENT_OK=true
RC=0
OUTPUT=""

begin() {
    CURRENT=$1
    CURRENT_OK=true
    echo
    echo "=== ${CURRENT}"
}

end() {
    if [[ "${CURRENT_OK}" == "true" ]]; then
        echo "--- PASS: ${CURRENT}"
        PASSED=$((PASSED + 1))
    else
        echo "--- FAIL: ${CURRENT}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${OUTPUT}"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${CURRENT}")
    fi
}

check() {
    local description=$1
    shift
    if "$@"; then
        echo "    ok: ${description}"
    else
        echo "    NOT OK: ${description}"
        CURRENT_OK=false
    fi
}

rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
file_has() { grep -qF -- "$2" "$1" 2> /dev/null; }
file_lacks() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
dir_is_empty() { [[ ! -d "$1" ]] || [[ -z "$(ls -A "$1")" ]]; }

# A fake zap.sh that records its arguments, environment, and plan, optionally
# copies a canned report into ZAP_REPORT_DIR, and exits with FAKE_RC.
FAKE_BIN="${WORK}/fake-bin"
FAKE_STATE="${WORK}/fake-state"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/zap.sh" << 'EOF'
#!/bin/bash
if [[ "$*" == "-cmd -version" ]]; then
    echo "${FAKE_ZAP_VERSION:-2.17.0}"
    exit 0
fi
mkdir -p "${FAKE_STATE}"
printf '%s\n' "$@" > "${FAKE_STATE}/args"
printf '%s\n%s\n' "${ZAP_TARGET}" "${ZAP_REPORT_DIR}" > "${FAKE_STATE}/env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -dir) mkdir -p "$2" && echo "fake zap log" > "$2/zap.log"; shift ;;
        -autorun) cp "$2" "${FAKE_STATE}/plan"; shift ;;
    esac
    shift
done
if [[ -n "${FAKE_REPORT:-}" ]]; then
    cp "${FAKE_REPORT}" "${ZAP_REPORT_DIR}/report.json"
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "${FAKE_BIN}/zap.sh"

# Writes a minimal traditional-json report with one alert per riskcode given.
make_report() {
    local dest=$1
    shift
    local alerts="" code
    for code in "$@"; do
        alerts+="${alerts:+,}{\"name\": \"Alert ${code}\", \"riskcode\": \"${code}\"}"
    done
    printf '{"site": [{"alerts": [%s]}]}\n' "${alerts}" > "${dest}"
}
make_report "${WORK}/report-none.json"
make_report "${WORK}/report-low.json" 1 1 0
make_report "${WORK}/report-medium.json" 2 1
make_report "${WORK}/report-high.json" 3 2 0
make_report "${WORK}/report-info.json" 0

# Nothing listens here, so connections are refused immediately.
DEAD_TARGET="http://127.0.0.1:9/"

# run_scan [VAR=value ...] -- runs the scan script against the fake zap.sh with
# a clean set of parameters, overridden by the given assignments. Sets RC and
# OUTPUT. Pass PATH=... to use a different zap.sh. BASH_ENV is unset because
# bash would otherwise source the PATH and ZAP_VERSION written by install.
REPORTS="${WORK}/reports"
run_scan() {
    rm -rf "${FAKE_STATE}" "${REPORTS}"
    mkdir -p "${WORK}/tmp"
    OUTPUT=$(env -u BASH_ENV -u ZAP_VERSION -u FAKE_RC -u FAKE_REPORT \
        PATH="${FAKE_BIN}:${PATH}" \
        TMPDIR="${WORK}/tmp" \
        FAKE_STATE="${FAKE_STATE}" \
        ZAP_VERSION="2.17.0" \
        PARAM_TARGET="${DEAD_TARGET}" \
        PARAM_SCAN_TYPE="baseline" \
        PARAM_API_DEFINITION="" \
        PARAM_PLAN="" \
        PARAM_FAIL_ON="medium" \
        PARAM_SPIDER_MINUTES="1" \
        PARAM_ACTIVE_SCAN_MINUTES="10" \
        PARAM_WAIT_FOR_TARGET="0" \
        PARAM_MAX_MEMORY="1g" \
        PARAM_REPORT_DIR="${REPORTS}" \
        PARAM_EXTRA_OPTIONS="" \
        "$@" \
        bash "${SCRIPT}" 2>&1)
    RC=$?
}

# Succeeds if the fake zap.sh received exactly these arguments, in order.
args_are() {
    diff <(printf '%s\n' "$@") "${FAKE_STATE}/args" > /dev/null
}

# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------

expect_rejected() {
    local description=$1
    local message=$2
    shift 2
    begin "rejects ${description}"
    run_scan "$@"
    check "exit code is non-zero" rc_is_nonzero
    check "explained the failure" output_has "${message}"
    check "did not run ZAP" test ! -e "${FAKE_STATE}/args"
    end
}

expect_rejected "a non-http target" "Invalid target 'ftp://example.com/'" PARAM_TARGET="ftp://example.com/"
expect_rejected "a target containing whitespace" "Expected an http:// or https:// URL" PARAM_TARGET="http://a b/"
expect_rejected "a missing target" "'target' is required unless a custom 'plan' is provided" PARAM_TARGET=""
expect_rejected "an unknown scan_type" "Invalid scan_type 'quick'" PARAM_SCAN_TYPE="quick"
expect_rejected "an unknown fail_on" "Invalid fail_on 'critical'" PARAM_FAIL_ON="critical"
expect_rejected "a capitalized fail_on" "Invalid fail_on 'High'" PARAM_FAIL_ON="High"
expect_rejected "an api scan without a definition" "'api_definition' is required when scan_type is api" \
    PARAM_SCAN_TYPE="api"
expect_rejected "a missing api_definition file" "API definition '${WORK}/nope.json' does not exist" \
    PARAM_SCAN_TYPE="api" PARAM_API_DEFINITION="${WORK}/nope.json"
expect_rejected "a missing plan file" "Automation Framework plan '${WORK}/nope.yaml' does not exist" \
    PARAM_PLAN="${WORK}/nope.yaml"
expect_rejected "a fractional spider_minutes" "'spider_minutes' must be a non-negative integer, got '1.5'" \
    PARAM_SPIDER_MINUTES="1.5"
expect_rejected "a negative active_scan_minutes" "'active_scan_minutes' must be a non-negative integer, got '-1'" \
    PARAM_ACTIVE_SCAN_MINUTES="-1"
expect_rejected "a non-numeric wait_for_target" "'wait_for_target' must be a non-negative integer, got 'soon'" \
    PARAM_WAIT_FOR_TARGET="soon"
expect_rejected "a malformed max_memory" "Invalid max_memory '1gb'" PARAM_MAX_MEMORY="1gb"
expect_rejected "a relative report_dir" "'report_dir' must be an absolute path, got 'reports'" \
    PARAM_REPORT_DIR="reports"
expect_rejected "ZAP older than 2.12.0" "Scanning requires ZAP 2.12.0 or newer, but ZAP 2.11.1 is installed" \
    ZAP_VERSION="2.11.1"
expect_rejected "an old ZAP detected with zap.sh -version" \
    "Scanning requires ZAP 2.12.0 or newer, but ZAP 2.10.0 is installed" \
    ZAP_VERSION="" FAKE_ZAP_VERSION="2.10.0"

begin "fails when zap.sh is not on the PATH"
mkdir -p "${WORK}/no-zap-bin"
for tool in bash env grep sed head tail cat wc tr mkdir mktemp rm cp sort dirname basename; do
    ln -sf "$(command -v "${tool}")" "${WORK}/no-zap-bin/${tool}"
done
run_scan PATH="${WORK}/no-zap-bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "zap.sh was not found on the PATH. Run the install command before scanning."
end

begin "accepts the minimum ZAP version"
run_scan ZAP_VERSION="2.12.0" FAKE_REPORT="${WORK}/report-none.json"
check "exit code is zero" rc_is_zero
end

# ---------------------------------------------------------------------------
# Generated plans
# ---------------------------------------------------------------------------

begin "baseline plan"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_SPIDER_MINUTES="3"
check "exit code is zero" rc_is_zero
check "targets the URL" file_has "${FAKE_STATE}/plan" "- '${DEAD_TARGET}'"
check "spiders for spider_minutes" file_has "${FAKE_STATE}/plan" "maxDuration: 3"
check "waits for the passive scan" file_has "${FAKE_STATE}/plan" "type: passiveScan-wait"
check "does not active scan" file_lacks "${FAKE_STATE}/plan" "activeScan"
check "does not import an API" file_lacks "${FAKE_STATE}/plan" "openapi"
check "writes an HTML report" file_has "${FAKE_STATE}/plan" "template: traditional-html"
check "writes a JSON report" file_has "${FAKE_STATE}/plan" "template: traditional-json"
check "writes a Markdown report" file_has "${FAKE_STATE}/plan" "template: traditional-md"
check "reports into report_dir" file_has "${FAKE_STATE}/plan" "reportDir: '${REPORTS}'"
check "has no exitStatus job, which older ZAP releases reject" file_lacks "${FAKE_STATE}/plan" "exitStatus"
check "plan saved beside the reports" diff -q "${FAKE_STATE}/plan" "${REPORTS}/plan.yaml"
check "ZAP log saved beside the reports" file_has "${REPORTS}/zap.log" "fake zap log"
end

begin "full plan"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_SCAN_TYPE="full" PARAM_ACTIVE_SCAN_MINUTES="7"
check "exit code is zero" rc_is_zero
check "spiders" file_has "${FAKE_STATE}/plan" "type: spider"
check "active scans for active_scan_minutes" file_has "${FAKE_STATE}/plan" "maxScanDurationInMins: 7"
end

begin "api plan with a relative definition path"
mkdir -p "${WORK}/project/specs"
cp "${FIXTURES}/openapi.json" "${WORK}/project/specs/openapi.json"
cd "${WORK}/project" || exit 1
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_SCAN_TYPE="api" PARAM_API_DEFINITION="specs/openapi.json"
cd - > /dev/null || exit 1
check "exit code is zero" rc_is_zero
check "imports the definition by absolute path" file_has "${FAKE_STATE}/plan" "apiFile: '${WORK}/project/specs/openapi.json'"
check "overrides the definition's servers with the target" file_has "${FAKE_STATE}/plan" "targetUrl: '${DEAD_TARGET}'"
check "does not spider" file_lacks "${FAKE_STATE}/plan" "type: spider"
check "active scans" file_has "${FAKE_STATE}/plan" "type: activeScan"
end

begin "api plan with a definition URL"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_SCAN_TYPE="api" \
    PARAM_API_DEFINITION="https://example.com/openapi.json"
check "exit code is zero" rc_is_zero
check "imports the definition by URL" file_has "${FAKE_STATE}/plan" "apiUrl: 'https://example.com/openapi.json'"
check "does not treat it as a file" file_lacks "${FAKE_STATE}/plan" "apiFile"
end

begin "warns that api_definition is unused outside api scans"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_API_DEFINITION="${WORK}/nope.json"
check "exit code is zero" rc_is_zero
check "warned" output_has "'api_definition' is ignored unless scan_type is api"
end

begin "quotes YAML metacharacters in the target"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_TARGET="http://127.0.0.1:9/?q='x'#:{y}"
check "exit code is zero" rc_is_zero
check "target is a single-quoted scalar" file_has "${FAKE_STATE}/plan" "- 'http://127.0.0.1:9/?q=''x''#:{y}'"
end

begin "report_dir with spaces and a trailing slash"
spaced="${WORK}/with space/reports"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_REPORT_DIR="${spaced}/"
check "exit code is zero" rc_is_zero
check "created the directory" test -d "${spaced}"
check "trailing slash trimmed" file_has "${spaced}/plan.yaml" "reportDir: '${spaced}'"
check "report written" test -f "${spaced}/report.json"
end

begin "expands environment variables in parameters"
if command -v circleci &> /dev/null; then
    run_scan FAKE_REPORT="${WORK}/report-none.json" SCAN_TEST_HOST="127.0.0.1:9" PARAM_TARGET='http://${SCAN_TEST_HOST}/'
    check "exit code is zero" rc_is_zero
    check "target expanded" file_has "${FAKE_STATE}/plan" "- 'http://127.0.0.1:9/'"
else
    echo "    skipped: the CircleCI CLI is not available"
fi
end

# ---------------------------------------------------------------------------
# zap.sh invocation
# ---------------------------------------------------------------------------

begin "passes isolation, memory, and extra options to zap.sh"
# Files that the options would match if they were subject to pathname expansion.
mkdir -p "${WORK}/globs"
touch "${WORK}/globs/a.b=glob" "${WORK}/globs/c.d=x"
cd "${WORK}/globs" || exit 1
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_MAX_MEMORY="512m" \
    PARAM_EXTRA_OPTIONS="-config  a.b=* -config c.d=[x]"
cd - > /dev/null || exit 1
check "exit code is zero" rc_is_zero
zap_dir=$(sed -n '4p' "${FAKE_STATE}/args" 2> /dev/null)
plan_path=$(tail -n 1 "${FAKE_STATE}/args" 2> /dev/null)
check "passes the expected arguments in order" args_are -cmd -silent -dir "${zap_dir}" -Xmx512m \
    -config 'a.b=*' -config 'c.d=[x]' -autorun "${plan_path}"
check "uses a temporary ZAP home directory" test "${zap_dir#"${WORK}/tmp/"}" != "${zap_dir}"
check "passes an absolute plan path" test "${plan_path:0:1}" = "/"
end

begin "defaults to a 1g heap"
run_scan FAKE_REPORT="${WORK}/report-none.json" PARAM_MAX_MEMORY=""
check "exit code is zero" rc_is_zero
check "passed -Xmx1g" grep -qx -- "-Xmx1g" "${FAKE_STATE}/args"
end

begin "expands environment variables in extra_options"
if command -v circleci &> /dev/null; then
    run_scan FAKE_REPORT="${WORK}/report-none.json" SCAN_TEST_TIMEOUT="45" \
        PARAM_EXTRA_OPTIONS='-config connection.timeoutInSecs=${SCAN_TEST_TIMEOUT}'
    check "exit code is zero" rc_is_zero
    check "passed the expanded option" grep -qx -- "connection.timeoutInSecs=45" "${FAKE_STATE}/args"
else
    echo "    skipped: the CircleCI CLI is not available"
fi
end

begin "cleans up temporary files"
run_scan FAKE_REPORT="${WORK}/report-none.json"
check "after a passing scan" dir_is_empty "${WORK}/tmp"
run_scan FAKE_REPORT="${WORK}/report-high.json"
check "after a failing scan" dir_is_empty "${WORK}/tmp"
run_scan FAKE_RC=1
check "after a ZAP failure" dir_is_empty "${WORK}/tmp"
end

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

expect_threshold() {
    local description=$1
    local fail_on=$2
    local report=$3
    local expected=$4
    local message=$5
    begin "${description}"
    run_scan PARAM_FAIL_ON="${fail_on}" FAKE_REPORT="${WORK}/${report}"
    if [[ "${expected}" == "pass" ]]; then
        check "exit code is zero" rc_is_zero
    else
        check "exit code is non-zero" rc_is_nonzero
    fi
    check "reported the outcome" output_has "${message}"
    end
}

expect_threshold "passes with no alerts" medium report-none.json pass "ZAP scan passed."
expect_threshold "passes with alerts below fail_on" medium report-low.json pass "ZAP scan passed."
expect_threshold "fails on an alert at fail_on" medium report-medium.json fail \
    "1 alert type(s) at or above fail_on 'medium'"
expect_threshold "counts every alert above fail_on" low report-high.json fail \
    "2 alert type(s) at or above fail_on 'low'"
expect_threshold "fail_on high ignores medium alerts" high report-medium.json pass "ZAP scan passed."
expect_threshold "fail_on info fails on informational alerts" info report-info.json fail \
    "1 alert type(s) at or above fail_on 'info'"
expect_threshold "fail_on never passes with high alerts" never report-high.json pass "ZAP scan passed."

begin "summarizes alerts by risk"
run_scan PARAM_FAIL_ON="never" FAKE_REPORT="${WORK}/report-high.json"
check "printed the counts" output_has "Alerts: 1 high, 1 medium, 0 low, 1 informational."
check "printed the report location" output_has "Reports written to ${REPORTS}."
end

begin "fails when ZAP reports plan errors"
run_scan FAKE_RC=1 FAKE_REPORT="${WORK}/report-none.json"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "ZAP scan failed (exit code 1)"
end

begin "fails when ZAP crashes"
run_scan FAKE_RC=137
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "ZAP scan failed (exit code 137)"
end

begin "passes with a warning when ZAP reports plan warnings"
run_scan FAKE_RC=2 FAKE_REPORT="${WORK}/report-none.json"
check "exit code is zero" rc_is_zero
check "warned" output_has "WARN: ZAP scan passed with plan warnings."
end

begin "plan warnings do not mask a threshold failure"
run_scan FAKE_RC=2 FAKE_REPORT="${WORK}/report-medium.json"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "1 alert type(s) at or above fail_on 'medium'"
end

begin "fails when ZAP writes no report"
run_scan
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "ZAP did not write ${REPORTS}/report.json."
end

begin "ignores reports left by an earlier scan"
stale="${WORK}/stale-reports"
mkdir -p "${stale}"
cp "${WORK}/report-none.json" "${stale}/report.json"
echo "keep me" > "${stale}/notes.txt"
run_scan PARAM_REPORT_DIR="${stale}"
check "exit code is non-zero" rc_is_nonzero
check "did not use the stale report" output_has "ZAP did not write ${stale}/report.json."
check "left unrelated files alone" file_has "${stale}/notes.txt" "keep me"
end

# ---------------------------------------------------------------------------
# Custom plans
# ---------------------------------------------------------------------------

begin "custom plan"
mkdir -p "${WORK}/project/.zap"
cp "${FIXTURES}/custom-plan.yaml" "${WORK}/project/.zap/plan.yaml"
cd "${WORK}/project" || exit 1
run_scan FAKE_REPORT="${WORK}/report-high.json" PARAM_PLAN=".zap/plan.yaml" PARAM_SCAN_TYPE="api" \
    PARAM_TARGET="http://127.0.0.1:9/app"
cd - > /dev/null || exit 1
check "exit code is zero despite high alerts, since fail_on is ignored" rc_is_zero
check "ran the plan unchanged" diff -q "${WORK}/project/.zap/plan.yaml" "${FAKE_STATE}/plan"
check "passed an absolute plan path" test "$(tail -n 1 "${FAKE_STATE}/args")" = "${WORK}/project/.zap/plan.yaml"
check "exported ZAP_TARGET" test "$(sed -n 1p "${FAKE_STATE}/env")" = "http://127.0.0.1:9/app"
check "exported ZAP_REPORT_DIR" test "$(sed -n 2p "${FAKE_STATE}/env")" = "${REPORTS}"
check "did not copy the plan into the reports" test ! -e "${REPORTS}/plan.yaml"
check "still summarized report.json" output_has "Alerts: 1 high"
end

begin "custom plan without a target or report"
run_scan PARAM_PLAN="${FIXTURES}/custom-plan.yaml" PARAM_TARGET="" PARAM_WAIT_FOR_TARGET="60"
check "exit code is zero" rc_is_zero
check "did not wait for a target" output_lacks "Waiting up to"
end

begin "custom plan that fails"
run_scan PARAM_PLAN="${FIXTURES}/custom-plan.yaml" FAKE_RC=1
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "ZAP scan failed (exit code 1)"
end

# ---------------------------------------------------------------------------
# Waiting for the target
# ---------------------------------------------------------------------------

begin "gives up on a target that never responds"
start=${SECONDS}
run_scan PARAM_WAIT_FOR_TARGET="3"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "${DEAD_TARGET} did not respond within 3s."
check "gave up promptly" test $((SECONDS - start)) -le 10
check "did not run ZAP" test ! -e "${FAKE_STATE}/args"
end

begin "waits for an https target with a self-signed certificate"
if command -v python3 &> /dev/null && command -v openssl &> /dev/null; then
    tls="${WORK}/tls"
    mkdir -p "${tls}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
        -keyout "${tls}/key.pem" -out "${tls}/cert.pem" &> /dev/null
    python3 - "${tls}" > "${tls}/port" 2> /dev/null << 'EOF' &
import http.server, ssl, sys
server = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(f"{sys.argv[1]}/cert.pem", f"{sys.argv[1]}/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_address[1], flush=True)
server.serve_forever()
EOF
    tls_pid=$!
    for _ in $(seq 1 50); do
        [[ -s "${tls}/port" ]] && break
        sleep 0.1
    done
    run_scan PARAM_TARGET="https://127.0.0.1:$(cat "${tls}/port")/" PARAM_WAIT_FOR_TARGET="5" \
        FAKE_REPORT="${WORK}/report-none.json"
    kill "${tls_pid}" 2> /dev/null
    check "exit code is zero" rc_is_zero
    check "did not time out" output_lacks "did not respond"
else
    echo "    skipped: python3 and openssl are required"
fi
end

begin "does not wait when wait_for_target is 0"
run_scan PARAM_WAIT_FOR_TARGET="0" FAKE_REPORT="${WORK}/report-none.json"
check "exit code is zero" rc_is_zero
check "did not wait" output_lacks "Waiting up to"
end

if [[ -n "${SCAN_TARGET:-}" ]]; then
    begin "waits for a responding target"
    run_scan PARAM_TARGET="${SCAN_TARGET}" PARAM_WAIT_FOR_TARGET="10" FAKE_REPORT="${WORK}/report-none.json"
    check "exit code is zero" rc_is_zero
    check "waited" output_has "Waiting up to 10s for ${SCAN_TARGET} to respond..."
    end

    begin "treats an HTTP error status as a response"
    run_scan PARAM_TARGET="${SCAN_TARGET%/}/no-such-page" PARAM_WAIT_FOR_TARGET="10" \
        FAKE_REPORT="${WORK}/report-none.json"
    check "exit code is zero" rc_is_zero
    check "did not time out" output_lacks "did not respond"
    end
fi

# ---------------------------------------------------------------------------
# Real scans
# ---------------------------------------------------------------------------

# run_real_scan [VAR=value ...] -- as run_scan, but with the real zap.sh and
# an isolated HOME.
run_real_scan() {
    rm -rf "${WORK:?}/home"
    mkdir -p "${WORK}/home"
    run_scan PATH="${PATH}" HOME="${WORK}/home" ZAP_VERSION="" PARAM_TARGET="${SCAN_TARGET}" \
        PARAM_WAIT_FOR_TARGET="30" "$@"
}

if [[ -z "${SCAN_TARGET:-}" ]] || ! command -v zap.sh &> /dev/null; then
    echo
    echo "Skipping real scans: set SCAN_TARGET and put zap.sh on the PATH to run them."
else
    begin "real baseline scan that fails on medium alerts"
    run_real_scan PARAM_FAIL_ON="medium"
    check "exit code is non-zero" rc_is_nonzero
    check "failed on the threshold rather than a ZAP error" output_has "at or above fail_on 'medium'"
    check "ZAP itself succeeded" output_lacks "ZAP scan failed"
    for report in report.html report.json report.md plan.yaml zap.log; do
        check "wrote ${report}" test -s "${REPORTS}/${report}"
    done
    check "found a known passive alert" file_has "${REPORTS}/report.json" "Missing Anti-clickjacking Header"
    check "did not touch ~/.ZAP" test ! -e "${WORK}/home/.ZAP"
    check "cleaned up temporary files" dir_is_empty "${WORK}/tmp"
    end

    begin "real baseline scan with fail_on never"
    run_real_scan PARAM_FAIL_ON="never"
    check "exit code is zero" rc_is_zero
    check "passed" output_has "ZAP scan passed."
    end

    begin "real full scan"
    run_real_scan PARAM_SCAN_TYPE="full" PARAM_FAIL_ON="never" PARAM_ACTIVE_SCAN_MINUTES="2"
    check "exit code is zero" rc_is_zero
    check "ran the active scan" output_has "Job activeScan finished"
    end

    begin "real api scan"
    run_real_scan PARAM_SCAN_TYPE="api" PARAM_FAIL_ON="never" PARAM_ACTIVE_SCAN_MINUTES="2" \
        PARAM_API_DEFINITION="${FIXTURES}/openapi.json"
    check "exit code is zero" rc_is_zero
    check "imported the definition" output_has "Job openapi added"
    check "scanned an operation from the definition" file_has "${REPORTS}/report.json" "/api/items"
    end

    begin "real custom plan that raises warnings"
    run_real_scan PARAM_PLAN="${FIXTURES}/custom-plan.yaml"
    check "exit code is zero" rc_is_zero
    check "passed with a warning" output_has "WARN: ZAP scan passed with plan warnings."
    check "wrote the plan's report" test -s "${REPORTS}/custom.json"
    end

    begin "real scan of an unreachable target"
    run_real_scan PARAM_TARGET="${DEAD_TARGET}" PARAM_WAIT_FOR_TARGET="0"
    check "exit code is non-zero" rc_is_nonzero
    check "reported the ZAP failure" output_has "ZAP scan failed (exit code 1)"
    end
fi

# ---------------------------------------------------------------------------

echo
echo "Passed: ${PASSED}, Failed: ${FAILED}"
if [[ "${FAILED}" -gt 0 ]]; then
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
