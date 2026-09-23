#!/bin/bash

set -eo pipefail

# Expands environment variables (e.g. $HOME) in parameter values. Falls back to
# the literal value on images that don't ship the CircleCI CLI.
expand() {
    local value=$1
    local expanded
    if [[ -z "${value}" ]]; then
        return 0
    fi
    # Passed on stdin, since values starting with "-" would be parsed as flags.
    if command -v circleci &> /dev/null && expanded=$(printf '%s' "${value}" | circleci env subst 2> /dev/null); then
        printf '%s' "${expanded}"
    else
        printf '%s' "${value}"
    fi
}

# Removes trailing slashes, leaving "/" intact.
trim_slash() {
    local value=$1
    while [[ "${value}" == */ ]] && [[ "${value}" != "/" ]]; do
        value=${value%/}
    done
    printf '%s' "${value}"
}

# Read in orb parameters
TARGET=$(expand "${PARAM_TARGET:-}")
SCAN_TYPE="${PARAM_SCAN_TYPE:-baseline}"
API_DEFINITION=$(expand "${PARAM_API_DEFINITION:-}")
PLAN=$(expand "${PARAM_PLAN:-}")
FAIL_ON="${PARAM_FAIL_ON:-medium}"
SPIDER_MINUTES="${PARAM_SPIDER_MINUTES:-1}"
ACTIVE_SCAN_MINUTES="${PARAM_ACTIVE_SCAN_MINUTES:-10}"
WAIT_FOR_TARGET="${PARAM_WAIT_FOR_TARGET:-60}"
MAX_MEMORY="${PARAM_MAX_MEMORY:-1g}"
REPORT_DIR=$(trim_slash "${PARAM_REPORT_DIR:-/tmp/zap-reports}")
EXTRA_OPTIONS=$(expand "${PARAM_EXTRA_OPTIONS:-}")

# Print command arguments for debugging purposes.
echo "Running ZAP scan..."
if [[ -n "${PLAN}" ]]; then
    echo "  PLAN: ${PLAN}"
else
    echo "  SCAN_TYPE: ${SCAN_TYPE}"
    echo "  FAIL_ON: ${FAIL_ON}"
fi
echo "  TARGET: ${TARGET}"
echo "  REPORT_DIR: ${REPORT_DIR}"

# The first ZAP release whose bundled Automation Framework supports every job
# and report template used by the generated plans.
MIN_ZAP_VERSION="2.12.0"

# Succeeds if semver $1 sorts strictly before semver $2.
version_lt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Maps a fail_on value to the lowest ZAP riskcode that fails the scan. The
# threshold is evaluated here rather than with the Automation Framework's
# exitStatus job, which only exists from ZAP 2.16.0 onward.
risk_code() {
    case "$1" in
        high) echo 3 ;;
        medium) echo 2 ;;
        low) echo 1 ;;
        info) echo 0 ;;
        never) echo "" ;;
        *) return 1 ;;
    esac
}

# Quotes a value as a single-quoted YAML scalar.
yaml_quote() {
    printf "'%s'" "${1//\'/\'\'}"
}

# ----------------------------------------------------------------------------
# Input validation
# ----------------------------------------------------------------------------

if [[ -n "${TARGET}" ]] && [[ ! "${TARGET}" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "ERROR: Invalid target '${TARGET}'. Expected an http:// or https:// URL."
    exit 1
fi

for number_param in "spider_minutes:${SPIDER_MINUTES}" "active_scan_minutes:${ACTIVE_SCAN_MINUTES}" \
    "wait_for_target:${WAIT_FOR_TARGET}"; do
    if [[ ! "${number_param#*:}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: '${number_param%%:*}' must be a non-negative integer, got '${number_param#*:}'."
        exit 1
    fi
done

if [[ ! "${MAX_MEMORY}" =~ ^[0-9]+[kKmMgG]$ ]]; then
    echo "ERROR: Invalid max_memory '${MAX_MEMORY}'. Expected a Java heap size such as 1g or 512m."
    exit 1
fi

if [[ "${REPORT_DIR}" != /* ]]; then
    echo "ERROR: 'report_dir' must be an absolute path, got '${REPORT_DIR}'."
    exit 1
fi

if [[ -n "${PLAN}" ]]; then
    if [[ ! -f "${PLAN}" ]]; then
        echo "ERROR: Automation Framework plan '${PLAN}' does not exist."
        exit 1
    fi
    # zap.sh changes into its install directory, so the plan path must be absolute.
    PLAN=$(cd "$(dirname "${PLAN}")" && pwd)/$(basename "${PLAN}")
else
    if [[ -z "${TARGET}" ]]; then
        echo "ERROR: 'target' is required unless a custom 'plan' is provided."
        exit 1
    fi
    case "${SCAN_TYPE}" in
        baseline | full | api) ;;
        *)
            echo "ERROR: Invalid scan_type '${SCAN_TYPE}'. Expected baseline, full, or api."
            exit 1
            ;;
    esac
    if ! FAIL_CODE=$(risk_code "${FAIL_ON}"); then
        echo "ERROR: Invalid fail_on '${FAIL_ON}'. Expected high, medium, low, info, or never."
        exit 1
    fi
    if [[ "${SCAN_TYPE}" == "api" ]]; then
        if [[ -z "${API_DEFINITION}" ]]; then
            echo "ERROR: 'api_definition' is required when scan_type is api."
            exit 1
        fi
        if [[ ! "${API_DEFINITION}" =~ ^https?:// ]]; then
            if [[ ! -f "${API_DEFINITION}" ]]; then
                echo "ERROR: API definition '${API_DEFINITION}' does not exist."
                exit 1
            fi
            API_DEFINITION=$(cd "$(dirname "${API_DEFINITION}")" && pwd)/$(basename "${API_DEFINITION}")
        fi
    elif [[ -n "${API_DEFINITION}" ]]; then
        echo "WARN: 'api_definition' is ignored unless scan_type is api."
    fi
fi

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------

if ! command -v zap.sh &> /dev/null; then
    echo "ERROR: zap.sh was not found on the PATH. Run the install command before scanning."
    exit 1
fi

ZAP_VERSION="${ZAP_VERSION:-}"
if [[ -z "${ZAP_VERSION}" ]]; then
    ZAP_VERSION=$(zap.sh -cmd -version 2> /dev/null | tail -n 1 || true)
fi
if [[ "${ZAP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_lt "${ZAP_VERSION}" "${MIN_ZAP_VERSION}"; then
    echo "ERROR: Scanning requires ZAP ${MIN_ZAP_VERSION} or newer, but ZAP ${ZAP_VERSION} is installed."
    exit 1
fi

# ----------------------------------------------------------------------------
# Wait for the target
# ----------------------------------------------------------------------------

# Any HTTP response counts, since the root of an API often returns 404. This
# only checks reachability, so certificates aren't verified: ZAP accepts the
# self-signed certificates that applications under test commonly use.
target_responds() {
    if command -v curl &> /dev/null; then
        curl -sS -k -o /dev/null --max-time 5 "${TARGET}" 2> /dev/null
    elif command -v wget &> /dev/null; then
        local rc=0
        wget -q -O /dev/null --no-check-certificate --tries=1 --timeout=5 "${TARGET}" 2> /dev/null || rc=$?
        # wget exits 8 when the server responds with an error status.
        [[ "${rc}" == "0" ]] || [[ "${rc}" == "8" ]]
    else
        return 0
    fi
}

if [[ -n "${TARGET}" ]] && [[ "${WAIT_FOR_TARGET}" -gt 0 ]]; then
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo "WARN: Neither curl nor wget is available, so not waiting for the target."
    else
        echo "Waiting up to ${WAIT_FOR_TARGET}s for ${TARGET} to respond..."
        deadline=$((SECONDS + WAIT_FOR_TARGET))
        until target_responds; do
            if [[ "${SECONDS}" -ge "${deadline}" ]]; then
                echo "ERROR: ${TARGET} did not respond within ${WAIT_FOR_TARGET}s."
                exit 1
            fi
            sleep 2
        done
    fi
fi

# ----------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------

# Clear this command's outputs from any earlier scan into the same directory,
# so stale results are never mistaken for this scan's.
mkdir -p "${REPORT_DIR}"
rm -f "${REPORT_DIR}"/{report.html,report.json,report.md,plan.yaml,zap.log}
ZAP_HOME=$(mktemp -d)
trap 'rm -rf "${ZAP_HOME}"' EXIT

# Custom plans can reference these as ${ZAP_TARGET} and ${ZAP_REPORT_DIR}.
export ZAP_TARGET="${TARGET}"
export ZAP_REPORT_DIR="${REPORT_DIR}"

if [[ -z "${PLAN}" ]]; then
    PLAN="${ZAP_HOME}/plan.yaml"
    {
        echo "env:"
        echo "  contexts:"
        echo "    - name: target"
        echo "      urls:"
        echo "        - $(yaml_quote "${TARGET}")"
        echo "  parameters:"
        echo "    failOnError: true"
        echo "    failOnWarning: false"
        echo "    progressToStdout: true"
        echo "jobs:"
        echo "  - type: passiveScan-config"
        echo "    parameters:"
        echo "      maxAlertsPerRule: 10"
        if [[ "${SCAN_TYPE}" == "api" ]]; then
            echo "  - type: openapi"
            echo "    parameters:"
            if [[ "${API_DEFINITION}" =~ ^https?:// ]]; then
                echo "      apiUrl: $(yaml_quote "${API_DEFINITION}")"
            else
                echo "      apiFile: $(yaml_quote "${API_DEFINITION}")"
            fi
            echo "      targetUrl: $(yaml_quote "${TARGET}")"
        else
            echo "  - type: spider"
            echo "    parameters:"
            echo "      context: target"
            echo "      maxDuration: ${SPIDER_MINUTES}"
        fi
        echo "  - type: passiveScan-wait"
        if [[ "${SCAN_TYPE}" != "baseline" ]]; then
            echo "  - type: activeScan"
            echo "    parameters:"
            echo "      context: target"
            echo "      maxScanDurationInMins: ${ACTIVE_SCAN_MINUTES}"
        fi
        for report in "traditional-html:report.html" "traditional-json:report.json" "traditional-md:report.md"; do
            echo "  - type: report"
            echo "    parameters:"
            echo "      template: ${report%%:*}"
            echo "      reportDir: $(yaml_quote "${REPORT_DIR}")"
            echo "      reportFile: ${report#*:}"
        done
    } > "${PLAN}"
    cp "${PLAN}" "${REPORT_DIR}/plan.yaml"
    GENERATED_PLAN="true"
fi

# ----------------------------------------------------------------------------
# Scan
# ----------------------------------------------------------------------------

# Split extra options on whitespace, without pathname expansion.
EXTRA_ARGS=()
read -r -a EXTRA_ARGS <<< "${EXTRA_OPTIONS}"

# An isolated home directory keeps runs independent of any ~/.ZAP config, and
# an explicit heap size stops the JVM sizing itself from the host's memory
# rather than the container's. -silent stops ZAP making unsolicited requests,
# such as update checks and telemetry, to its own services.
ZAP_RC=0
zap.sh -cmd -silent -dir "${ZAP_HOME}/home" "-Xmx${MAX_MEMORY}" "${EXTRA_ARGS[@]}" -autorun "${PLAN}" || ZAP_RC=$?
cp "${ZAP_HOME}/home/zap.log" "${REPORT_DIR}/zap.log" 2> /dev/null || true

# ----------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------

# Counts alert types (not instances) with the given riskcode.
count_risk() {
    { grep -oE "\"riskcode\": ?\"$1\"" "${REPORT_DIR}/report.json" || true; } | wc -l | tr -d ' '
}

declare -a ALERT_COUNTS
if [[ -f "${REPORT_DIR}/report.json" ]]; then
    for code in 0 1 2 3; do
        ALERT_COUNTS[code]=$(count_risk "${code}")
    done
    echo "Alerts: ${ALERT_COUNTS[3]} high, ${ALERT_COUNTS[2]} medium, ${ALERT_COUNTS[1]} low, ${ALERT_COUNTS[0]} informational."
fi
echo "Reports written to ${REPORT_DIR}."

# ZAP exits 1 for plan errors and 2 for plan warnings. Warnings, such as a
# custom plan's exitStatus warnLevel being reached, don't fail the step.
if [[ "${ZAP_RC}" != "0" ]] && [[ "${ZAP_RC}" != "2" ]]; then
    echo "ERROR: ZAP scan failed (exit code ${ZAP_RC}). See the plan errors above."
    exit 1
fi

if [[ "${GENERATED_PLAN:-false}" == "true" ]]; then
    if [[ ! -f "${REPORT_DIR}/report.json" ]]; then
        echo "ERROR: ZAP did not write ${REPORT_DIR}/report.json."
        exit 1
    fi
    if [[ -n "${FAIL_CODE}" ]]; then
        failing=0
        for ((code = FAIL_CODE; code <= 3; code++)); do
            failing=$((failing + ALERT_COUNTS[code]))
        done
        if [[ "${failing}" -gt 0 ]]; then
            echo "ERROR: ${failing} alert type(s) at or above fail_on '${FAIL_ON}'. See the reports for details."
            exit 1
        fi
    fi
fi

if [[ "${ZAP_RC}" == "2" ]]; then
    echo "WARN: ZAP scan passed with plan warnings. See the output above."
else
    echo "ZAP scan passed."
fi
