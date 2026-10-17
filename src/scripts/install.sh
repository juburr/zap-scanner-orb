#!/bin/bash
#
# Installs ZAP for the install command: the release archive, unpacked into its
# own directory, verified against the checksum table in this file before it is
# installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (ZAP only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing ZAP needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="zap-scanner-orb"
TOOL_NAME="ZAP"
TOOL_BINARY="zap.sh"
TOOL_ARCHES="noarch"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="zap"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'ZAP_%s_Linux.tar.gz\n' "$1"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order. The ZAP project keeps only recent releases in its main
# repository and moves older ones to zap-archive, so a pinned version
# eventually migrates.
tool_asset_urls() {
    printf 'https://github.com/zaproxy/zaproxy/releases/download/v%s/%s\n' "$1" "$3"
    printf 'https://github.com/zaproxy/zap-archive/releases/download/zap-v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: empty, since ZAP installs as a whole
# directory. The checksum table holds the SHA-512 of the release archive.
tool_archive_member() {
    :
}

# Releases whose zap.sh declares a lower minimum Java version than their
# bytecode actually requires. ZAP 2.16.0's launcher says Java 11, but its
# classes are compiled for Java 17 and fail to load on anything older.
declare -A zap_min_java_overrides=(
    ["2.16.0"]="17"
)

# Succeeds if version $1 sorts strictly before version $2.
zap_version_lt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# ZAP is a Java application that installs as a directory, with zap.sh linked
# into bin_path, so it replaces the shared single-binary install.
tool_install() {
    local bin_path java_bin java_version java_major java_package min_java override
    local marker zap_sh staging=""

    bin_path=$(orb_dir_param bin_path "${PARAM_BIN_PATH:-}" bin)
    orb_info "  bin_path:         ${bin_path}"
    ORB_BIN_DIR=${bin_path}
    orb_require_tools tar gzip sort cut

    # ZAP does not bundle a JRE on Linux. Fail before downloading a ~250 MB
    # archive if Java is missing, selecting it the way the release's zap.sh
    # will: JAVA_HOME is honored from 2.17.0 onward, while earlier launchers
    # only use the java found on the PATH.
    java_bin="java"
    if ! zap_version_lt "${ORB_VERSION}" "2.17.0" && [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        java_bin="${JAVA_HOME}/bin/java"
    fi
    if ! command -v "${java_bin}" > /dev/null 2>&1; then
        # Releases before 2.6.0 only run on Java 7 or 8.
        java_package="java-21-openjdk-headless"
        if zap_version_lt "${ORB_VERSION}" "2.6.0"; then
            java_package="java-1.8.0-openjdk-headless"
        fi
        if zap_version_lt "${ORB_VERSION}" "2.17.0"; then
            orb_die "ZAP requires a Java runtime, but no java executable was found. ZAP ${ORB_VERSION} ignores" \
                "JAVA_HOME, so java must be on the PATH. On Red Hat UBI images, install one in an earlier step" \
                "with 'dnf install -y ${java_package}' (microdnf on ubi-minimal)."
        fi
        orb_die "ZAP requires a Java runtime, but no java executable was found. Use an executor that includes" \
            "Java, such as cimg/openjdk:21.0, or set JAVA_HOME. On Red Hat UBI images, install one in an earlier" \
            "step with 'dnf install -y ${java_package}' (microdnf on ubi-minimal)."
    fi

    # Java 8 and earlier report versions as 1.<major>.
    java_version=$("${java_bin}" -version 2>&1 | awk -F\" '/version/ { print $2 }' | head -n 1 || true)
    java_major=${java_version%%[.-]*}
    if [[ "${java_major}" == "1" ]]; then
        java_major=$(cut -d. -f2 <<< "${java_version}")
    fi
    if [[ ! "${java_major}" =~ ^[0-9]+$ ]]; then
        orb_die "Unable to determine the Java version from '${java_bin} -version'."
    fi
    # The launchers shipped before ZAP 2.6.0 only understand 1.x version
    # strings and refuse to start on Java 9 or newer.
    if zap_version_lt "${ORB_VERSION}" "2.6.0" && [[ "${java_major}" -gt 8 ]]; then
        orb_die "ZAP ${ORB_VERSION} only runs on Java 7 or 8, but found Java ${java_version}." \
            "Use an executor such as cimg/openjdk:8.0, or put a Java 8 runtime first on the PATH."
    fi

    if zap_version_lt "${ORB_VERSION}" "$(orb_latest_version)"; then
        orb_warn "ZAP ${ORB_VERSION} is not the latest release ($(orb_latest_version)). The ZAP project only supports"
        orb_warn "its latest full release, and older releases may contain known vulnerabilities."
    fi

    # A marker is written after every successful install so that repeated
    # invocations in the same job are idempotent. It records the archive's
    # SHA-512, so an install that wasn't verified (verify_checksums: false)
    # can't pass for a verified one. Anything else already in install_path is
    # left untouched rather than deleted, since the path is user-supplied.
    marker="${ORB_INSTALL_PATH}/.zap-scanner-orb"
    if [[ -f "${marker}" ]] && grep -qxF "version=${ORB_VERSION}" "${marker}"; then
        if [[ -n "${ORB_EXPECTED_SHA512}" ]] && ! grep -qxF "sha512=${ORB_EXPECTED_SHA512}" "${marker}"; then
            orb_die "${ORB_INSTALL_PATH} holds a ZAP ${ORB_VERSION} install whose archive doesn't match this orb's checksum." \
                "Remove the directory, or choose a different install_path."
        fi
        orb_info "ZAP ${ORB_VERSION} is already installed at ${ORB_INSTALL_PATH}. Skipping the download."
        zap_sh="${ORB_INSTALL_PATH}/zap.sh"
    else
        if [[ -e "${ORB_INSTALL_PATH}" && ! -d "${ORB_INSTALL_PATH}" ]]; then
            orb_die "${ORB_INSTALL_PATH} exists and is not a directory."
        elif [[ -d "${ORB_INSTALL_PATH}" && -n "$(ls -A "${ORB_INSTALL_PATH}")" ]]; then
            orb_die "${ORB_INSTALL_PATH} already exists and is not empty. Choose a different install_path or remove the directory first."
        fi
        orb_fetch_verified
        # Extract into a staging directory beside install_path, then move it
        # into place, so a failed install never leaves a partly populated
        # directory. The archive holds a single top-level ZAP_<version>/.
        mkdir -p "$(dirname "${ORB_INSTALL_PATH}")"
        staging=$(mktemp -d "$(dirname "${ORB_INSTALL_PATH}")/.zap-install.XXXXXX")
        ORB_CLEANUP+=("${staging}")
        tar -xzf "${ORB_VERIFIED_FILE}" -o -C "${staging}" --strip-components=1
        if [[ ! -f "${staging}/zap.sh" || ! -f "${staging}/zap-${ORB_VERSION}.jar" ]]; then
            orb_die "The extracted archive does not look like a ZAP ${ORB_VERSION} release."
        fi
        chmod +x "${staging}/zap.sh"
        zap_sh="${staging}/zap.sh"
    fi

    # Compare against the minimum Java version declared by the release's own
    # launcher, so a mismatch is reported here rather than on the first scan.
    min_java=$(grep -oE 'minimum of Java [0-9]+' "${zap_sh}" | awk '{ print $4 }' | head -n 1 || true)
    override=${zap_min_java_overrides[${ORB_VERSION}]:-}
    if [[ -n "${override}" && "${override}" -gt "${min_java:-0}" ]]; then
        min_java=${override}
    fi
    if [[ -n "${min_java}" && "${java_major}" -lt "${min_java}" ]]; then
        orb_die "ZAP ${ORB_VERSION} requires Java ${min_java} or newer, but found Java ${java_version}."
    fi

    if [[ -n "${staging}" ]]; then
        # An unverified install may run without sha512sum. Its marker then has
        # no sha512 line, which a later verified install refuses.
        {
            printf 'version=%s\n' "${ORB_VERSION}"
            if command -v sha512sum > /dev/null 2>&1; then
                printf 'sha512=%s\n' "$(sha512sum "${ORB_VERIFIED_FILE}" | awk '{ print $1 }')"
            fi
        } > "${staging}/.zap-scanner-orb"
        chmod 755 "${staging}"
        if [[ -d "${ORB_INSTALL_PATH}" ]]; then
            rmdir "${ORB_INSTALL_PATH}"
        fi
        mv "${staging}" "${ORB_INSTALL_PATH}"
    fi

    # zap.sh dereferences symlinks to locate its install directory, so a plain
    # symlink is enough to put it on the PATH.
    mkdir -p "${bin_path}"
    ln -sfn "${ORB_INSTALL_PATH}/zap.sh" "${bin_path}/zap.sh"
    if [[ -n "${BASH_ENV:-}" ]]; then
        {
            printf 'export ZAP_INSTALL_PATH=%q\n' "${ORB_INSTALL_PATH}"
            printf 'export ZAP_VERSION=%q\n' "${ORB_VERSION}"
        } >> "${BASH_ENV}"
    fi
    orb_info "Linked ${bin_path}/zap.sh (Java ${java_version})."
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
#
# Every entry is anchored to a checksum the ZAP project published; see
# upstream_checksums.txt for the source of each. ZAP 2.0.0 through 2.3.1,
# 2.4.1, and 2.6.0 are no longer hosted by the ZAP project and cannot be
# installed.
declare -A sha512sums=(
    ["2.17.0/noarch"]="e0ea4974fcff6143d7293d04f758327575ee0e8ee7f80befd2122b3d6718d0c5b0e35eabf5ebd9edc638dfec57a0a3e02b01b68b589e24de08d75aaadcd93ac8"
    ["2.16.1/noarch"]="f61694f6710cbd9bac60928e6f46c69858898a10ac95c46d5df142a853d60e89e380d9242138b7b9aed2358aecf357b965700b9e84f41a42fac8829b6e6494ca"
    ["2.16.0/noarch"]="ccf5c04aca02c1ba8b4e9e65b2815b47fc17cc6b5ae41841615cf3ac557dac402218149a38fc635f57f3db76205046fafa67d6959e19884ca7d085af8413bb16"
    ["2.15.0/noarch"]="293437bcd3516f516cf56a35bab9ad482f00f5391e0946cb77bb7857047f8b7633517659b7945d33813e78f8677223a34c9b58136aac3af1155fce0d7a30fea1"
    ["2.14.0/noarch"]="32f4f24be304f1300a588e2cd87933f0cbe26fbd3cd4ce39ef30ebd7c8f277da83717e73b5861056293afbd2dda13e97f4f970e4386a31a28e11f5b429eebbad"
    ["2.13.0/noarch"]="a9646c8f15b55519816067e84f08692ca9d85b90fc9fae4244f0c0b55561cbda28fb2b287b0832c2d86b191b32752894de9a994c2e4dba87a05e5ffccfeef6b5"
    ["2.12.0/noarch"]="9385bdfcb167f6c3091f6f83ecfc5a97312bf4cce411b0f81765ad6fb3022402eb0b7dbbf1772186a196673c84645c6e7b558b745cbbcd575764380f5d34aaa5"
    ["2.11.1/noarch"]="e31c0e48b05f6e6baef751ac760f7dbde17431f69f9a14c7280ed68a473b4c1eb5558889b5e45b3e7b09cb9b76208fb86871e67e7a5eee904b21dfa0ba582f11"
    ["2.11.0/noarch"]="263ba41dd3afa3dfa1b057d5f310f177beea11493186947dd1eeb03b52f6f05ab78f2668e71e26aac06ce6f3f85450805fc583da509555f2fac668ab516ea58c"
    ["2.10.0/noarch"]="bde386b359e304e5d1463cb23382de1c116b0a90eebb694517a4c79c9f7ec4442f94cd41cf6cb5b58a357ebf31477ca11d729f300a6c7744ad02096d3b6de5d0"
    ["2.9.0/noarch"]="0e348250564e307d5d88be0d22801f07ea3f0a831cd12a15b87e4fcce006b3392ec42285b197585fe2b163e76a15c77add749e2c38cf608c519bae055f2304f7"
    # ZAP never published a checksum for 2.8.1, a Kali-only bug fix release, so
    # this entry is pinned to the archive served by the ZAP project on GitHub.
    ["2.8.1/noarch"]="1cff2c6a99d404cb82ffd8b5a3a9bb223e2d9bfbc1ae009566ba6d11f5b3e2376d217b6ae2e0babc6515ab16852a5880081961ddec88b104c6afc3b2ff61cf53"
    ["2.8.0/noarch"]="f3f6ace4fb2304b62a080cba3b3d58dc5d42af181ce71e42def7f89d82b3d41d54c87b80e9379f4c6a4b1bbefb6d21deac25392f32951f0afe419968d2178519"
    ["2.7.0/noarch"]="7d98fb930bd179af141215387fb0f62b49e1040cb9942abe09dba1a2bb4df2af05cab18e4b67fbdfd29a3171fd2a8e6e59e7b17aedf9dd7030dfb16e95919488"
    ["2.5.0/noarch"]="070c2a1ae8193e79e50d21ea38702a9bd6fdba5c1fc73308b3c79be44589f5ffaff1809c48d0fbe6db39d4369ea477b85e3f57f8b90ad674043d7e1970b3696b"
    ["2.4.3/noarch"]="ec28e3acd8eb71707984bd0cf55099bcec21dfaf4ce515b3d47573ea349d1935ad44cfc64e1fdd4bf09fa58fee6eb6229e1640e0c9d6a910fdbbc0d4b6254ca2"
    ["2.4.2/noarch"]="b10028f8e3175ec34fd082de7b1b9b49a00781f50f071433345a7a8b8622b109447ac366e596cccef4b5b5cb504421d77894b8d63f6d0e0babe9320334c10b92"
    ["2.4.0/noarch"]="7b61ac7ebaf6bd98bfe647b4583da5e1d488b1eea093dd4174c45a0ad51268ce7d6f5ea10d3e3ac27aaa299bf94980e78cc6ccb538d186b96612764e1161fbb1"
)
# <<< checksum table <<<

orb_install_main
