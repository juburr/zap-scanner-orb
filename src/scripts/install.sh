#!/bin/bash

set -eo pipefail

# Expands environment variables (e.g. $HOME) in parameter values. Falls back to
# the literal value on images that don't ship the CircleCI CLI.
expand() {
    local value=$1
    local expanded
    # circleci env subst reads stdin when given an empty argument.
    if [[ -z "${value}" ]]; then
        return 0
    fi
    if command -v circleci &> /dev/null && expanded=$(circleci env subst "${value}" 2> /dev/null); then
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
INSTALL_PATH=$(trim_slash "$(expand "${PARAM_INSTALL_PATH:-}")")
BIN_PATH=$(trim_slash "$(expand "${PARAM_BIN_PATH:-}")")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS:-strict}"
VERSION=$(expand "${PARAM_VERSION:-}")
DOWNLOAD_DIR="${ZAP_ORB_DOWNLOAD_DIR:-/tmp/zap-orb-download}"
INSTALL_PATH="${INSTALL_PATH:-${HOME}/zap}"
BIN_PATH="${BIN_PATH:-${HOME}/bin}"

# Print command arguments for debugging purposes.
echo "Running ZAP installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  BIN_PATH: ${BIN_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for the ZAP_<version>_Linux.tar.gz release
# archives. Generate new entries with scripts/install_hash.sh, which also checks
# the download against ZAP's own published checksum for that release; see
# scripts/upstream_checksums.txt for the provenance of every entry.
# ZAP 2.0.0 through 2.3.1, 2.4.1, and 2.6.0 are no longer hosted by the ZAP
# project and cannot be installed.
declare -A sha512sums
sha512sums=(
    ["2.17.0"]="e0ea4974fcff6143d7293d04f758327575ee0e8ee7f80befd2122b3d6718d0c5b0e35eabf5ebd9edc638dfec57a0a3e02b01b68b589e24de08d75aaadcd93ac8"
    ["2.16.1"]="f61694f6710cbd9bac60928e6f46c69858898a10ac95c46d5df142a853d60e89e380d9242138b7b9aed2358aecf357b965700b9e84f41a42fac8829b6e6494ca"
    ["2.16.0"]="ccf5c04aca02c1ba8b4e9e65b2815b47fc17cc6b5ae41841615cf3ac557dac402218149a38fc635f57f3db76205046fafa67d6959e19884ca7d085af8413bb16"
    ["2.15.0"]="293437bcd3516f516cf56a35bab9ad482f00f5391e0946cb77bb7857047f8b7633517659b7945d33813e78f8677223a34c9b58136aac3af1155fce0d7a30fea1"
    ["2.14.0"]="32f4f24be304f1300a588e2cd87933f0cbe26fbd3cd4ce39ef30ebd7c8f277da83717e73b5861056293afbd2dda13e97f4f970e4386a31a28e11f5b429eebbad"
    ["2.13.0"]="a9646c8f15b55519816067e84f08692ca9d85b90fc9fae4244f0c0b55561cbda28fb2b287b0832c2d86b191b32752894de9a994c2e4dba87a05e5ffccfeef6b5"
    ["2.12.0"]="9385bdfcb167f6c3091f6f83ecfc5a97312bf4cce411b0f81765ad6fb3022402eb0b7dbbf1772186a196673c84645c6e7b558b745cbbcd575764380f5d34aaa5"
    ["2.11.1"]="e31c0e48b05f6e6baef751ac760f7dbde17431f69f9a14c7280ed68a473b4c1eb5558889b5e45b3e7b09cb9b76208fb86871e67e7a5eee904b21dfa0ba582f11"
    ["2.11.0"]="263ba41dd3afa3dfa1b057d5f310f177beea11493186947dd1eeb03b52f6f05ab78f2668e71e26aac06ce6f3f85450805fc583da509555f2fac668ab516ea58c"
    ["2.10.0"]="bde386b359e304e5d1463cb23382de1c116b0a90eebb694517a4c79c9f7ec4442f94cd41cf6cb5b58a357ebf31477ca11d729f300a6c7744ad02096d3b6de5d0"
    ["2.9.0"]="0e348250564e307d5d88be0d22801f07ea3f0a831cd12a15b87e4fcce006b3392ec42285b197585fe2b163e76a15c77add749e2c38cf608c519bae055f2304f7"
    # ZAP never published a checksum for 2.8.1, a Kali-only bug fix release, so
    # this entry is pinned to the archive served by the ZAP project on GitHub.
    ["2.8.1"]="1cff2c6a99d404cb82ffd8b5a3a9bb223e2d9bfbc1ae009566ba6d11f5b3e2376d217b6ae2e0babc6515ab16852a5880081961ddec88b104c6afc3b2ff61cf53"
    ["2.8.0"]="f3f6ace4fb2304b62a080cba3b3d58dc5d42af181ce71e42def7f89d82b3d41d54c87b80e9379f4c6a4b1bbefb6d21deac25392f32951f0afe419968d2178519"
    ["2.7.0"]="7d98fb930bd179af141215387fb0f62b49e1040cb9942abe09dba1a2bb4df2af05cab18e4b67fbdfd29a3171fd2a8e6e59e7b17aedf9dd7030dfb16e95919488"
    ["2.5.0"]="070c2a1ae8193e79e50d21ea38702a9bd6fdba5c1fc73308b3c79be44589f5ffaff1809c48d0fbe6db39d4369ea477b85e3f57f8b90ad674043d7e1970b3696b"
    ["2.4.3"]="ec28e3acd8eb71707984bd0cf55099bcec21dfaf4ce515b3d47573ea349d1935ad44cfc64e1fdd4bf09fa58fee6eb6229e1640e0c9d6a910fdbbc0d4b6254ca2"
    ["2.4.2"]="b10028f8e3175ec34fd082de7b1b9b49a00781f50f071433345a7a8b8622b109447ac366e596cccef4b5b5cb504421d77894b8d63f6d0e0babe9320334c10b92"
    ["2.4.0"]="7b61ac7ebaf6bd98bfe647b4583da5e1d488b1eea093dd4174c45a0ad51268ce7d6f5ea10d3e3ac27aaa299bf94980e78cc6ccb538d186b96612764e1161fbb1"
)

# Releases whose zap.sh declares a lower minimum Java version than their
# bytecode actually requires. ZAP 2.16.0's launcher says Java 11, but its
# classes are compiled for Java 17 and fail to load on anything older.
declare -A min_java_overrides
min_java_overrides=(
    ["2.16.0"]="17"
)

# Succeeds if semver $1 sorts strictly before semver $2.
version_lt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# ----------------------------------------------------------------------------
# Input validation
# ----------------------------------------------------------------------------

# The version is interpolated into the download URL, so only accept plain semver.
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid ZAP version '${VERSION}'. Expected a semver such as 2.17.0."
    exit 1
fi

case "${VERIFY_CHECKSUMS}" in
    false|known_versions|strict) ;;
    *)
        echo "ERROR: Invalid verify_checksums value '${VERIFY_CHECKSUMS}'. Expected false, known_versions, or strict."
        exit 1
        ;;
esac

# The zap.sh symlink points at an absolute target, and relative paths would
# resolve against whatever directory the step happens to run in.
for path_param in "install_path:${INSTALL_PATH}" "bin_path:${BIN_PATH}"; do
    if [[ "${path_param#*:}" != /* ]]; then
        echo "ERROR: '${path_param%%:*}' must be an absolute path, got '${path_param#*:}'."
        exit 1
    fi
done

EXPECTED_CHECKSUM="${sha512sums[${VERSION}]:-}"
if [[ "${VERIFY_CHECKSUMS}" == "false" ]]; then
    echo "WARN: Checksum validation is disabled. This is not recommended."
    EXPECTED_CHECKSUM=""
elif [[ -z "${EXPECTED_CHECKSUM}" ]]; then
    # A new version of ZAP was released but this orb hasn't been updated yet to
    # include its checksum in the lookup table. Strict mode (recommended) treats
    # this as a hard error; known_versions allows the install to continue.
    if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
        echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
        echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
        echo "WARN: Skipping checksum verification..."
    else
        echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
        echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------

for tool in tar gzip sha512sum sort cut; do
    if ! command -v "${tool}" &> /dev/null; then
        echo "ERROR: Required tool '${tool}' is not available."
        exit 1
    fi
done

# ZAP is a Java application and does not bundle a JRE on Linux. Fail before
# downloading a ~250 MB archive if Java is missing entirely. Select Java the
# same way the release's zap.sh will: JAVA_HOME is honored from 2.17.0 onward,
# while earlier launchers only use the java found on the PATH.
JAVA_BIN="java"
if ! version_lt "${VERSION}" "2.17.0" && [[ -n "${JAVA_HOME:-}" ]] && [[ -x "${JAVA_HOME}/bin/java" ]]; then
    JAVA_BIN="${JAVA_HOME}/bin/java"
fi
if ! command -v "${JAVA_BIN}" &> /dev/null; then
    echo "ERROR: ZAP requires a Java runtime, but no java executable was found."
    if version_lt "${VERSION}" "2.17.0"; then
        echo "ERROR: ZAP ${VERSION} ignores JAVA_HOME, so java must be on the PATH."
    else
        echo "ERROR: Use an executor that includes Java, such as cimg/openjdk:21.0, or set JAVA_HOME."
    fi
    exit 1
fi

# Java 8 and earlier report versions as 1.<major>.
JAVA_VERSION=$("${JAVA_BIN}" -version 2>&1 | awk -F\" '/version/ { print $2 }' | head -n 1 || true)
JAVA_MAJOR_VERSION=${JAVA_VERSION%%[.-]*}
if [[ "${JAVA_MAJOR_VERSION}" == "1" ]]; then
    JAVA_MAJOR_VERSION=$(cut -d. -f2 <<< "${JAVA_VERSION}")
fi
if [[ ! "${JAVA_MAJOR_VERSION}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Unable to determine the Java version from '${JAVA_BIN} -version'."
    exit 1
fi

# The launchers shipped before ZAP 2.6.0 only understand 1.x version strings
# and refuse to start on Java 9 or newer.
if version_lt "${VERSION}" "2.6.0" && [[ "${JAVA_MAJOR_VERSION}" -gt 8 ]]; then
    echo "ERROR: ZAP ${VERSION} only runs on Java 7 or 8, but found Java ${JAVA_VERSION}."
    echo "ERROR: Use an executor such as cimg/openjdk:8.0, or set JAVA_HOME to a Java 8 runtime."
    exit 1
fi

if command -v curl &> /dev/null; then
    DOWNLOADER="curl"
elif command -v wget &> /dev/null; then
    DOWNLOADER="wget"
else
    echo "ERROR: Neither curl nor wget is available. Please install one of them."
    exit 1
fi

LATEST_VERSION=$(printf '%s\n' "${!sha512sums[@]}" | sort -V | tail -n 1)
if version_lt "${VERSION}" "${LATEST_VERSION}"; then
    echo "WARN: ZAP ${VERSION} is not the latest release (${LATEST_VERSION}). The ZAP project only supports"
    echo "WARN: its latest full release, and older releases may contain known vulnerabilities."
fi

# ----------------------------------------------------------------------------
# Existing installs
# ----------------------------------------------------------------------------

# A marker is written after every successful install so that repeated
# invocations in the same job are idempotent. Anything else already occupying
# install_path is left untouched rather than deleted, since the path is
# user-supplied.
MARKER="${INSTALL_PATH}/.zap-scanner-orb"
ALREADY_INSTALLED="false"
if [[ -f "${MARKER}" ]] && grep -qx "version=${VERSION}" "${MARKER}"; then
    echo "ZAP ${VERSION} is already installed at ${INSTALL_PATH}. Skipping download."
    ALREADY_INSTALLED="true"
elif [[ -e "${INSTALL_PATH}" ]] && [[ ! -d "${INSTALL_PATH}" ]]; then
    echo "ERROR: ${INSTALL_PATH} exists and is not a directory."
    exit 1
elif [[ -d "${INSTALL_PATH}" ]] && [[ -n "$(ls -A "${INSTALL_PATH}")" ]]; then
    echo "ERROR: ${INSTALL_PATH} already exists and is not empty."
    echo "ERROR: Choose a different 'install_path' or remove the directory first."
    exit 1
fi

# ----------------------------------------------------------------------------
# Download and verify
# ----------------------------------------------------------------------------

sha512_of() {
    sha512sum "$1" | awk '{ print $1 }'
}

# Tries each URL in turn. Download to a temporary name so an interrupted
# transfer is never cached.
download() {
    local dest=$1
    shift
    local url
    for url in "$@"; do
        echo "Downloading ${url}..."
        if [[ "${DOWNLOADER}" == "curl" ]]; then
            if curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused "${url}" -o "${dest}.partial"; then
                mv "${dest}.partial" "${dest}"
                return 0
            fi
        elif wget -q --tries=5 --waitretry=2 "${url}" -O "${dest}.partial"; then
            mv "${dest}.partial" "${dest}"
            return 0
        fi
        echo "Not available from ${url}."
    done
    rm -f "${dest}.partial"
    echo "ERROR: Unable to download ZAP ${VERSION}. Confirm that it is a published ZAP release."
    exit 1
}

verify_checksum() {
    local file=$1
    local actual_checksum
    actual_checksum=$(sha512_of "${file}")

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${EXPECTED_CHECKSUM}"

    if [[ "${actual_checksum}" != "${EXPECTED_CHECKSUM}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

if [[ "${ALREADY_INSTALLED}" == "false" ]]; then
    # Cache restoration is handled in install.yml
    TARBALL="${DOWNLOAD_DIR}/zap.tar.gz"
    # The ZAP project keeps only recent releases in its main repository and
    # moves older ones to zap-archive, so a pinned version eventually migrates.
    URLS=(
        "https://github.com/zaproxy/zaproxy/releases/download/v${VERSION}/ZAP_${VERSION}_Linux.tar.gz"
        "https://github.com/zaproxy/zap-archive/releases/download/zap-v${VERSION}/ZAP_${VERSION}_Linux.tar.gz"
    )
    mkdir -p "${DOWNLOAD_DIR}"

    if [[ -f "${TARBALL}" ]]; then
        echo "Using cached ZAP ${VERSION} archive."
        # A cached archive that no longer matches is discarded and fetched again
        # (and re-verified) rather than failing every future build on this key.
        if [[ -n "${EXPECTED_CHECKSUM}" ]] && [[ "$(sha512_of "${TARBALL}")" != "${EXPECTED_CHECKSUM}" ]]; then
            echo "WARN: Cached archive does not match the expected checksum. Discarding it and re-downloading..."
            rm -f "${TARBALL}"
        fi
    fi

    if [[ ! -f "${TARBALL}" ]]; then
        download "${TARBALL}" "${URLS[@]}"
    fi

    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        verify_checksum "${TARBALL}"
    fi

    # Extract into a staging directory beside install_path, then move it into
    # place, so a failed install never leaves a partially populated directory.
    PARENT_DIR=$(dirname "${INSTALL_PATH}")
    mkdir -p "${PARENT_DIR}"
    STAGING_DIR=$(mktemp -d "${PARENT_DIR}/.zap-install.XXXXXX")
    trap 'rm -rf "${STAGING_DIR}"' EXIT

    # The archive contains a single top-level ZAP_<version>/ directory.
    tar -xzf "${TARBALL}" -C "${STAGING_DIR}" --strip-components=1 --no-same-owner
    if [[ ! -f "${STAGING_DIR}/zap.sh" ]] || [[ ! -f "${STAGING_DIR}/zap-${VERSION}.jar" ]]; then
        echo "ERROR: The extracted archive does not look like a ZAP ${VERSION} release."
        exit 1
    fi
    chmod +x "${STAGING_DIR}/zap.sh"
    ZAP_SH="${STAGING_DIR}/zap.sh"
else
    ZAP_SH="${INSTALL_PATH}/zap.sh"
fi

# ----------------------------------------------------------------------------
# Java version
# ----------------------------------------------------------------------------

# Compare against the minimum Java version declared by the launcher that ships
# with this ZAP release, so the failure is reported here rather than on the
# first scan.
MIN_JAVA=$(grep -oE 'minimum of Java [0-9]+' "${ZAP_SH}" | awk '{ print $4 }' | head -n 1 || true)
OVERRIDE_JAVA="${min_java_overrides[${VERSION}]:-}"
if [[ -n "${OVERRIDE_JAVA}" ]] && [[ "${OVERRIDE_JAVA}" -gt "${MIN_JAVA:-0}" ]]; then
    MIN_JAVA="${OVERRIDE_JAVA}"
fi
if [[ -n "${MIN_JAVA}" ]] && [[ "${JAVA_MAJOR_VERSION}" -lt "${MIN_JAVA}" ]]; then
    echo "ERROR: ZAP ${VERSION} requires Java ${MIN_JAVA} or newer, but found Java ${JAVA_VERSION}."
    exit 1
fi

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------

if [[ "${ALREADY_INSTALLED}" == "false" ]]; then
    printf 'version=%s\nsha512=%s\n' "${VERSION}" "$(sha512_of "${TARBALL}")" > "${STAGING_DIR}/.zap-scanner-orb"
    chmod 755 "${STAGING_DIR}"
    if [[ -d "${INSTALL_PATH}" ]]; then
        rmdir "${INSTALL_PATH}"
    fi
    mv "${STAGING_DIR}" "${INSTALL_PATH}"
    trap - EXIT
fi

# zap.sh dereferences symlinks to locate its install directory, so a plain
# symlink is enough to put it on the PATH.
mkdir -p "${BIN_PATH}"
ln -sfn "${INSTALL_PATH}/zap.sh" "${BIN_PATH}/zap.sh"

if [[ -n "${BASH_ENV:-}" ]]; then
    {
        if [[ ":${PATH}:" != *":${BIN_PATH}:"* ]]; then
            # ${PATH} is expanded when BASH_ENV is sourced, not now.
            # shellcheck disable=SC2016
            printf 'export PATH=%q:"${PATH}"\n' "${BIN_PATH}"
        fi
        printf 'export ZAP_INSTALL_PATH=%q\n' "${INSTALL_PATH}"
        printf 'export ZAP_VERSION=%q\n' "${VERSION}"
    } >> "${BASH_ENV}"
fi

echo "Installed ZAP ${VERSION} to ${INSTALL_PATH} (Java ${JAVA_VERSION})."
