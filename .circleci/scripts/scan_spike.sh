#!/bin/bash

# Runs one ZAP Automation Framework plan with zap.sh -autorun and asserts on
# the result. Prototype for the scan command; requires zap.sh on the PATH.
#
# Usage: scan_spike.sh <name> <plan> <expected_exit> [pattern...]
#   name           Label for the run; reports go to ${REPORT_ROOT}/<name>.
#   plan           Automation Framework plan file.
#   expected_exit  0 (clean), 1 (plan errors), or 2 (plan warnings).
#   pattern        Extended regex that must match report.json. Repeatable.
#
# Environment:
#   ZAP_TARGET      URL to scan.
#   ZAP_WARN_LEVEL  Lowest alert risk that makes the plan exit 2. Substituted
#                   here, since ZAP doesn't expand variables in exitStatus.
#   ZAP_API_FILE    OpenAPI definition, for plans that import one.
#   REPORT_ROOT     Defaults to /tmp/zap-reports.

set -uo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <name> <plan> <expected_exit> [pattern...]"
    exit 64
fi

name=$1
plan_template=$2
expected_exit=$3
shift 3

case "${ZAP_WARN_LEVEL:-}" in
    High | Medium | Low | Info) ;;
    *)
        echo "ZAP_WARN_LEVEL must be High, Medium, Low, or Info"
        exit 64
        ;;
esac

export ZAP_REPORT_DIR="${REPORT_ROOT:-/tmp/zap-reports}/${name}"
mkdir -p "${ZAP_REPORT_DIR}"
zap_home=$(mktemp -d)

# zap.sh changes into its install directory, so the plan path must be absolute.
plan="${zap_home}/plan.yaml"
sed "s/\${ZAP_WARN_LEVEL}/${ZAP_WARN_LEVEL}/g" "${plan_template}" > "${plan}"

start=$(date +%s)
zap.sh -cmd -dir "${zap_home}" -Xmx1g -autorun "${plan}" 2>&1 | tee "${ZAP_REPORT_DIR}/autorun.log"
rc=${PIPESTATUS[0]}
cp "${zap_home}/zap.log" "${ZAP_REPORT_DIR}/zap.log" 2> /dev/null || true
rm -rf "${zap_home}"
echo "${name}: exit ${rc} after $(($(date +%s) - start))s"

status=0
if [[ "${rc}" != "${expected_exit}" ]]; then
    echo "FAIL: expected exit ${expected_exit}, got ${rc}"
    status=1
fi

if [[ "${expected_exit}" != "1" ]]; then
    for report in report.html report.json; do
        if [[ ! -s "${ZAP_REPORT_DIR}/${report}" ]]; then
            echo "FAIL: ${report} was not written"
            status=1
        fi
    done
fi

for pattern in "$@"; do
    if ! grep -qE "${pattern}" "${ZAP_REPORT_DIR}/report.json" 2> /dev/null; then
        echo "FAIL: report.json does not match /${pattern}/"
        status=1
    fi
done

exit "${status}"
