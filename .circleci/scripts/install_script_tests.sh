#!/bin/bash

# Exercises src/scripts/install.sh directly, covering the failure and edge
# cases that can't be asserted through the orb command in a CircleCI job
# (which simply fails the job). Requires Java 17+ on the PATH.
#
# Optional environment:
#   SEED_ARCHIVE  Path to an already-downloaded ZAP_2.17.0_Linux.tar.gz, used to
#                 avoid re-downloading it (e.g. a restored CircleCI cache).

# Single-quoted snippets below are expanded by child shells, not this one.
# shellcheck disable=SC2016

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${REPO_ROOT}/src/scripts/install.sh"
VERSION="2.17.0"
ALT_VERSION="2.16.1"
# The smallest archived release, served only from zaproxy/zap-archive.
LEGACY_VERSION="2.4.0"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# Shared download cache for the default version, populated by the first test.
CACHE="${WORK}/cache"
mkdir -p "${CACHE}"
if [[ -n "${SEED_ARCHIVE:-}" ]] && [[ -f "${SEED_ARCHIVE}" ]]; then
    cp "${SEED_ARCHIVE}" "${CACHE}/zap.tar.gz"
fi

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

# run_install [VAR=value ...] -- runs the install script with a clean set of
# parameters, overridden by the given assignments. Sets RC and OUTPUT, and
# leaves whatever the script appended to BASH_ENV in ${BASH_ENV_FILE}.
BASH_ENV_FILE="${WORK}/bash_env"
run_install() {
    local script="${INSTALL_SCRIPT:-${SCRIPT}}"
    : > "${BASH_ENV_FILE}"
    OUTPUT=$(env \
        BASH_ENV="${BASH_ENV_FILE}" \
        ZAP_ORB_DOWNLOAD_DIR="${CACHE}" \
        PARAM_INSTALL_PATH="" \
        PARAM_BIN_PATH="" \
        PARAM_VERIFY_CHECKSUMS="strict" \
        PARAM_VERSION="${VERSION}" \
        "$@" \
        bash "${script}" 2>&1)
    RC=$?
}

# Sources the BASH_ENV written by the last run in a clean shell and prints the
# resolved zap.sh, ZAP_INSTALL_PATH and ZAP_VERSION, one per line.
resolve_env() {
    env -i HOME="${HOME}" PATH="/usr/bin:/bin" BASH_ENV="${BASH_ENV_FILE}" \
        bash -c 'command -v zap.sh; echo "${ZAP_INSTALL_PATH:-}"; echo "${ZAP_VERSION:-}"'
}

rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
dir_is_empty() { [[ ! -d "$1" ]] || [[ -z "$(ls -A "$1")" ]]; }
no_staging_dirs() { [[ -z "$(find "$1" -maxdepth 1 -name '.zap-install.*' 2> /dev/null)" ]]; }

# Builds a directory of symlinks to only the named tools, for tests that need
# a PATH without java, curl, or wget.
make_sandbox_path() {
    local dir=$1
    shift
    mkdir -p "${dir}"
    local tool
    for tool in "$@"; do
        if command -v "${tool}" &> /dev/null; then
            ln -sf "$(command -v "${tool}")" "${dir}/${tool}"
        fi
    done
}
BASE_TOOLS=(bash env awk grep sed head tail cat cut sort ls find mkdir mktemp mv rm rmdir ln chmod dirname tar gzip sha512sum)

# Writes a fake JAVA_HOME whose java prints the given -version banner.
make_fake_java() {
    local home=$1
    local banner=$2
    mkdir -p "${home}/bin"
    printf '#!/bin/sh\necho '"'"'%s'"'"' >&2\n' "${banner}" > "${home}/bin/java"
    chmod +x "${home}/bin/java"
}

# Copy of install.sh with the given version removed from the checksum table.
make_script_without_checksum() {
    local version=$1
    local dest=$2
    sed "/\[\"${version//./\\.}\"\]=/d" "${SCRIPT}" > "${dest}"
    ! grep -q "\[\"${version}\"\]=" "${dest}"
}

# ---------------------------------------------------------------------------
# Happy paths
# ---------------------------------------------------------------------------

begin "fresh install (strict)"
run_install PARAM_INSTALL_PATH="${WORK}/a/zap" PARAM_BIN_PATH="${WORK}/a/bin"
check "exit code is zero" rc_is_zero
check "checksum verified" output_has "Checksum verification passed!"
check "no unsupported-version warning for the latest release" output_lacks "is not the latest release"
check "zap.sh is executable" test -x "${WORK}/a/zap/zap.sh"
check "release jar present" test -f "${WORK}/a/zap/zap-${VERSION}.jar"
check "symlink points at install" test "$(readlink "${WORK}/a/bin/zap.sh")" = "${WORK}/a/zap/zap.sh"
check "marker records version" grep -qx "version=${VERSION}" "${WORK}/a/zap/.zap-scanner-orb"
check "no staging directories left" no_staging_dirs "${WORK}/a"
check "archive kept for caching" test -f "${CACHE}/zap.tar.gz"
check "no partial download left" test ! -e "${CACHE}/zap.tar.gz.partial"
version_output=$("${WORK}/a/bin/zap.sh" -cmd -version 2>&1)
check "zap.sh -cmd -version reports ${VERSION}" grep -qx "${VERSION}" <<< "${version_output}"
resolved=$(resolve_env)
check "BASH_ENV puts zap.sh on the PATH" test "$(sed -n 1p <<< "${resolved}")" = "${WORK}/a/bin/zap.sh"
check "BASH_ENV exports ZAP_INSTALL_PATH" test "$(sed -n 2p <<< "${resolved}")" = "${WORK}/a/zap"
check "BASH_ENV exports ZAP_VERSION" test "$(sed -n 3p <<< "${resolved}")" = "${VERSION}"
end

begin "cache hit"
run_install PARAM_INSTALL_PATH="${WORK}/c/zap" PARAM_BIN_PATH="${WORK}/c/bin"
check "exit code is zero" rc_is_zero
check "used cached archive" output_has "Using cached ZAP ${VERSION} archive."
check "did not download" output_lacks "Downloading"
check "cached archive still verified" output_has "Checksum verification passed!"
end

begin "idempotent re-install"
run_install PARAM_INSTALL_PATH="${WORK}/a/zap" PARAM_BIN_PATH="${WORK}/a/bin"
check "exit code is zero" rc_is_zero
check "detected existing install" output_has "already installed"
check "did not download" output_lacks "Downloading"
check "install still intact" test -f "${WORK}/a/zap/zap-${VERSION}.jar"
end

begin "paths with spaces, shell metacharacters and trailing slashes"
odd_dir="${WORK}/with space \$(touch ${WORK}/pwned) 'q'"
run_install PARAM_INSTALL_PATH="${odd_dir}/zap//" PARAM_BIN_PATH="${odd_dir}/bin/"
check "exit code is zero" rc_is_zero
check "trailing slashes trimmed" test -f "${odd_dir}/zap/zap.sh"
resolved=$(resolve_env)
check "zap.sh resolves on PATH after sourcing BASH_ENV" test "$(sed -n 1p <<< "${resolved}")" = "${odd_dir}/bin/zap.sh"
check "ZAP_INSTALL_PATH preserved" test "$(sed -n 2p <<< "${resolved}")" = "${odd_dir}/zap"
check "nothing was executed from the path" test ! -e "${WORK}/pwned"
end

begin "defaults to \$HOME/zap and \$HOME/bin"
mkdir -p "${WORK}/home"
run_install HOME="${WORK}/home"
check "exit code is zero" rc_is_zero
check "installed to \$HOME/zap" test -f "${WORK}/home/zap/zap.sh"
check "linked into \$HOME/bin" test -L "${WORK}/home/bin/zap.sh"
end

begin "bin_path already on PATH is not re-exported"
run_install PATH="${WORK}/onpath/bin:${PATH}" PARAM_INSTALL_PATH="${WORK}/onpath/zap" PARAM_BIN_PATH="${WORK}/onpath/bin"
check "exit code is zero" rc_is_zero
check "no PATH export written" bash -c '! grep -q "^export PATH=" "$1"' _ "${BASH_ENV_FILE}"
check "ZAP_INSTALL_PATH still exported" grep -q "^export ZAP_INSTALL_PATH=" "${BASH_ENV_FILE}"
end

begin "works without BASH_ENV"
run_install BASH_ENV="" PARAM_INSTALL_PATH="${WORK}/nobashenv/zap" PARAM_BIN_PATH="${WORK}/nobashenv/bin"
check "exit code is zero" rc_is_zero
check "installed" test -f "${WORK}/nobashenv/zap/zap.sh"
end

begin "environment variables in paths are expanded"
if command -v circleci &> /dev/null && circleci env subst 'x' &> /dev/null; then
    run_install ZAP_TEST_ROOT="${WORK}/expand" PARAM_INSTALL_PATH='${ZAP_TEST_ROOT}/zap' PARAM_BIN_PATH='$ZAP_TEST_ROOT/bin'
    check "exit code is zero" rc_is_zero
    check "install_path expanded" test -f "${WORK}/expand/zap/zap.sh"
    check "bin_path expanded" test -L "${WORK}/expand/bin/zap.sh"
else
    echo "    skipped: CircleCI CLI with 'env subst' is not available"
fi
end

begin "JAVA_HOME takes precedence over PATH"
make_fake_java "${WORK}/java99" 'openjdk version "99.0.1" 2099-01-01'
run_install JAVA_HOME="${WORK}/java99" PARAM_INSTALL_PATH="${WORK}/javahome/zap" PARAM_BIN_PATH="${WORK}/javahome/bin"
check "exit code is zero" rc_is_zero
check "reported the JAVA_HOME java" output_has "(Java 99.0.1)"
end

begin "known_versions installs an unknown version with a warning"
make_script_without_checksum "${VERSION}" "${WORK}/install_no_checksum.sh"
INSTALL_SCRIPT="${WORK}/install_no_checksum.sh" run_install PARAM_VERIFY_CHECKSUMS=known_versions \
    PARAM_INSTALL_PATH="${WORK}/known/zap" PARAM_BIN_PATH="${WORK}/known/bin"
check "exit code is zero" rc_is_zero
check "warned about missing checksum" output_has "WARN: No checksum available for version ${VERSION}"
check "skipped verification" output_lacks "Checksum verification passed!"
check "installed" test -f "${WORK}/known/zap/zap.sh"
end

begin "verify_checksums=false installs with a warning"
run_install PARAM_VERIFY_CHECKSUMS=false PARAM_INSTALL_PATH="${WORK}/nocheck/zap" PARAM_BIN_PATH="${WORK}/nocheck/bin"
check "exit code is zero" rc_is_zero
check "warned that validation is disabled" output_has "WARN: Checksum validation is disabled"
check "skipped verification" output_lacks "Checksum verification passed!"
end

begin "tampered cache is discarded and re-downloaded"
mkdir -p "${WORK}/tampered"
cp "${CACHE}/zap.tar.gz" "${WORK}/tampered/zap.tar.gz"
printf 'x' >> "${WORK}/tampered/zap.tar.gz"
run_install ZAP_ORB_DOWNLOAD_DIR="${WORK}/tampered" PARAM_INSTALL_PATH="${WORK}/t/zap" PARAM_BIN_PATH="${WORK}/t/bin"
check "exit code is zero" rc_is_zero
check "warned about the cached archive" output_has "Cached archive does not match"
check "re-downloaded" output_has "Downloading"
check "re-verified" output_has "Checksum verification passed!"
check "cache now holds the good archive" cmp -s "${CACHE}/zap.tar.gz" "${WORK}/tampered/zap.tar.gz"
rm -rf "${WORK}/tampered"
end

begin "installs an archived release from zap-archive on Java 8"
# Releases before 2.17.0 ignore JAVA_HOME, so the Java 8 on the PATH must be
# used rather than the (incompatible) Java 99 in JAVA_HOME.
make_fake_java "${WORK}/java8-ok" 'openjdk version "1.8.0_402"'
make_fake_java "${WORK}/java99-legacy" 'openjdk version "99.0.1" 2099-01-01'
run_install PATH="${WORK}/java8-ok/bin:${PATH}" JAVA_HOME="${WORK}/java99-legacy" \
    PARAM_VERSION="${LEGACY_VERSION}" ZAP_ORB_DOWNLOAD_DIR="${WORK}/legacy-dl" \
    PARAM_INSTALL_PATH="${WORK}/legacy/zap" PARAM_BIN_PATH="${WORK}/legacy/bin"
check "exit code is zero" rc_is_zero
check "warned that the release is unsupported" output_has "ZAP ${LEGACY_VERSION} is not the latest release"
check "fell back from the main repository" output_has "Not available from https://github.com/zaproxy/zaproxy/"
check "downloaded from zap-archive" output_has "https://github.com/zaproxy/zap-archive/releases/download/zap-v${LEGACY_VERSION}/"
check "verified" output_has "Checksum verification passed!"
check "installed ${LEGACY_VERSION}" test -f "${WORK}/legacy/zap/zap-${LEGACY_VERSION}.jar"
check "used the PATH java, ignoring JAVA_HOME" output_has "(Java 1.8.0_402)"
rm -rf "${WORK}/legacy-dl"
end

# ---------------------------------------------------------------------------
# Failure paths
# ---------------------------------------------------------------------------

begin "rejects Java 9+ for releases before 2.6.0 without downloading"
run_install PARAM_VERSION="${LEGACY_VERSION}" ZAP_ORB_DOWNLOAD_DIR="${WORK}/legacy-java-dl" \
    PARAM_INSTALL_PATH="${WORK}/legacy-java/zap" PARAM_BIN_PATH="${WORK}/legacy-java/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "ZAP ${LEGACY_VERSION} only runs on Java 7 or 8"
check "nothing downloaded" dir_is_empty "${WORK}/legacy-java-dl"
check "nothing installed" test ! -e "${WORK}/legacy-java/zap"
end

begin "releases before 2.17.0 require java on the PATH"
make_sandbox_path "${WORK}/sandbox-javahome-only" "${BASE_TOOLS[@]}" curl wget
run_install PATH="${WORK}/sandbox-javahome-only" JAVA_HOME="${WORK}/java8-ok" PARAM_VERSION="${LEGACY_VERSION}" \
    ZAP_ORB_DOWNLOAD_DIR="${WORK}/javahome-only-dl" \
    PARAM_INSTALL_PATH="${WORK}/javahome-only/zap" PARAM_BIN_PATH="${WORK}/javahome-only/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained that JAVA_HOME is ignored" output_has "ZAP ${LEGACY_VERSION} ignores JAVA_HOME, so java must be on the PATH"
check "nothing downloaded" dir_is_empty "${WORK}/javahome-only-dl"
end

begin "fails cleanly for a version that was never published"
run_install PARAM_VERSION="9.9.9" PARAM_VERIFY_CHECKSUMS=known_versions ZAP_ORB_DOWNLOAD_DIR="${WORK}/missing-dl" \
    PARAM_INSTALL_PATH="${WORK}/missing/zap" PARAM_BIN_PATH="${WORK}/missing/bin"
check "exit code is non-zero" rc_is_nonzero
check "tried the main repository" output_has "https://github.com/zaproxy/zaproxy/releases/download/v9.9.9/"
check "tried zap-archive" output_has "https://github.com/zaproxy/zap-archive/releases/download/zap-v9.9.9/"
check "explained the failure" output_has "Unable to download ZAP 9.9.9"
check "no partial download left" dir_is_empty "${WORK}/missing-dl"
check "nothing installed" test ! -e "${WORK}/missing/zap"
end

begin "strict mode rejects an unknown version before downloading"
INSTALL_SCRIPT="${WORK}/install_no_checksum.sh" run_install ZAP_ORB_DOWNLOAD_DIR="${WORK}/strict-dl2" \
    PARAM_INSTALL_PATH="${WORK}/strict2/zap" PARAM_BIN_PATH="${WORK}/strict2/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "No checksum available for version ${VERSION} and strict mode is enabled"
check "nothing downloaded" dir_is_empty "${WORK}/strict-dl2"
check "nothing installed" test ! -e "${WORK}/strict2/zap"
end

begin "tampered archive fails verification when it is freshly downloaded"
# Simulate a bad upstream by pointing the table at the wrong checksum.
sed "s/\[\"${VERSION//./\\.}\"\]=\"[0-9a-f]*\"/[\"${VERSION}\"]=\"$(printf '0%.0s' {1..128})\"/" "${SCRIPT}" > "${WORK}/install_bad_checksum.sh"
mkdir -p "${WORK}/badsum-dl"
cp "${CACHE}/zap.tar.gz" "${WORK}/badsum-dl/zap.tar.gz"
INSTALL_SCRIPT="${WORK}/install_bad_checksum.sh" run_install ZAP_ORB_DOWNLOAD_DIR="${WORK}/badsum-dl" \
    PARAM_INSTALL_PATH="${WORK}/badsum/zap" PARAM_BIN_PATH="${WORK}/badsum/bin"
check "exit code is non-zero" rc_is_nonzero
check "checksum verification failed" output_has "ERROR: Checksum verification failed!"
check "nothing installed" test ! -e "${WORK}/badsum/zap"
check "no staging directories left" no_staging_dirs "${WORK}/badsum"
check "no symlink created" test ! -e "${WORK}/badsum/bin/zap.sh"
rm -rf "${WORK}/badsum-dl"
end

begin "rejects malformed versions"
for bad_version in "" "latest" "2.17" "v2.17.0" "2.17.0-rc1" "2.17.0/../../evil" '2.17.0;id'; do
    run_install PARAM_VERSION="${bad_version}" PARAM_INSTALL_PATH="${WORK}/badver/zap" PARAM_BIN_PATH="${WORK}/badver/bin"
    check "'${bad_version}' is rejected" rc_is_nonzero
    check "'${bad_version}' explained" output_has "Invalid ZAP version"
done
check "nothing installed" test ! -e "${WORK}/badver/zap"
end

begin "rejects invalid verify_checksums"
run_install PARAM_VERIFY_CHECKSUMS=maybe PARAM_INSTALL_PATH="${WORK}/badverify/zap" PARAM_BIN_PATH="${WORK}/badverify/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "Invalid verify_checksums value 'maybe'"
end

begin "rejects relative paths"
run_install PARAM_INSTALL_PATH="relative/zap" PARAM_BIN_PATH="${WORK}/rel/bin"
check "relative install_path rejected" rc_is_nonzero
check "install_path explained" output_has "'install_path' must be an absolute path"
run_install PARAM_INSTALL_PATH="${WORK}/rel/zap" PARAM_BIN_PATH="bin"
check "relative bin_path rejected" rc_is_nonzero
check "bin_path explained" output_has "'bin_path' must be an absolute path"
end

begin "refuses a non-empty install_path"
mkdir -p "${WORK}/occupied/zap"
echo "keep me" > "${WORK}/occupied/zap/important.txt"
run_install PARAM_INSTALL_PATH="${WORK}/occupied/zap" PARAM_BIN_PATH="${WORK}/occupied/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "already exists and is not empty"
check "existing files untouched" grep -qx "keep me" "${WORK}/occupied/zap/important.txt"
end

begin "installs into an existing empty install_path"
mkdir -p "${WORK}/empty/zap"
run_install PARAM_INSTALL_PATH="${WORK}/empty/zap" PARAM_BIN_PATH="${WORK}/empty/bin"
check "exit code is zero" rc_is_zero
check "installed" test -f "${WORK}/empty/zap/zap.sh"
end

begin "refuses an install_path that is a file"
mkdir -p "${WORK}/file"
touch "${WORK}/file/zap"
run_install PARAM_INSTALL_PATH="${WORK}/file/zap" PARAM_BIN_PATH="${WORK}/file/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "exists and is not a directory"
end

begin "refuses to install a different version over an existing install"
run_install PARAM_VERSION="${ALT_VERSION}" PARAM_INSTALL_PATH="${WORK}/a/zap" PARAM_BIN_PATH="${WORK}/a/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "already exists and is not empty"
check "original install untouched" grep -qx "version=${VERSION}" "${WORK}/a/zap/.zap-scanner-orb"
end

begin "fails before downloading when Java is missing"
make_sandbox_path "${WORK}/sandbox-nojava" "${BASE_TOOLS[@]}" curl wget
run_install PATH="${WORK}/sandbox-nojava" JAVA_HOME="" ZAP_ORB_DOWNLOAD_DIR="${WORK}/nojava-dl" \
    PARAM_INSTALL_PATH="${WORK}/nojava/zap" PARAM_BIN_PATH="${WORK}/nojava/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "no java executable was found"
check "nothing downloaded" dir_is_empty "${WORK}/nojava-dl"
end

begin "rejects Java older than the release's minimum"
make_fake_java "${WORK}/java11" 'openjdk version "11.0.22" 2024-01-16'
run_install JAVA_HOME="${WORK}/java11" PARAM_INSTALL_PATH="${WORK}/java11-install/zap" PARAM_BIN_PATH="${WORK}/java11-install/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "requires Java 17 or newer, but found Java 11.0.22"
check "nothing installed" test ! -e "${WORK}/java11-install/zap"
check "no staging directories left" no_staging_dirs "${WORK}/java11-install"
end

begin "rejects Java 1.8-style version strings"
make_fake_java "${WORK}/java8" 'openjdk version "1.8.0_402"'
run_install JAVA_HOME="${WORK}/java8" PARAM_INSTALL_PATH="${WORK}/java8-install/zap" PARAM_BIN_PATH="${WORK}/java8-install/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "requires Java 17 or newer, but found Java 1.8.0_402"
end

begin "fails clearly on an unparseable Java version"
make_fake_java "${WORK}/javabad" 'something unexpected'
run_install JAVA_HOME="${WORK}/javabad" PARAM_INSTALL_PATH="${WORK}/javabad-install/zap" PARAM_BIN_PATH="${WORK}/javabad-install/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "Unable to determine the Java version"
check "nothing installed" test ! -e "${WORK}/javabad-install/zap"
end

begin "fails when neither curl nor wget is available"
make_sandbox_path "${WORK}/sandbox-nodl" "${BASE_TOOLS[@]}" java
run_install PATH="${WORK}/sandbox-nodl" ZAP_ORB_DOWNLOAD_DIR="${WORK}/nodl-dl" \
    PARAM_INSTALL_PATH="${WORK}/nodl/zap" PARAM_BIN_PATH="${WORK}/nodl/bin"
check "exit code is non-zero" rc_is_nonzero
check "explained the failure" output_has "Neither curl nor wget is available"
end

begin "downloads with wget when curl is unavailable"
if command -v wget &> /dev/null; then
    make_sandbox_path "${WORK}/sandbox-wget" "${BASE_TOOLS[@]}" java wget
    run_install PATH="${WORK}/sandbox-wget" ZAP_ORB_DOWNLOAD_DIR="${WORK}/wget-dl" PARAM_VERSION="${ALT_VERSION}" \
        PARAM_INSTALL_PATH="${WORK}/wget/zap" PARAM_BIN_PATH="${WORK}/wget/bin"
    check "exit code is zero" rc_is_zero
    check "downloaded" output_has "Downloading"
    check "verified" output_has "Checksum verification passed!"
    check "warned that the release is unsupported" output_has "ZAP ${ALT_VERSION} is not the latest release"
    check "installed ${ALT_VERSION}" test -f "${WORK}/wget/zap/zap-${ALT_VERSION}.jar"
    rm -rf "${WORK}/wget-dl"
else
    echo "    skipped: wget is not available"
fi
end

# ---------------------------------------------------------------------------

echo
echo "Passed: ${PASSED}, Failed: ${FAILED}"
if [[ "${FAILED}" -gt 0 ]]; then
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
